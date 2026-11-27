import DahliaRuntimeSupport
import Foundation
import GRDB

extension AgentInboxService {
    /// Deselected providers cancel pending signals; selected providers retain theirs across temporary fetch failures.
    func reconcileCalendar(_ snapshot: AgentCalendarSnapshot, now: Date = .now, calendar: Calendar = .current) throws {
        let successful = snapshot.successfulProviders.intersection(snapshot.selectedProviders ?? snapshot.successfulProviders)
        try dbQueue.write { db in
            // Selection invalidation applies to retained signals even while their source is paused.
            if let selected = snapshot.selectedProviders {
                let pending = try AgentEventRecord.fetchAll(db, sql: """
                SELECT e.* FROM agent_event_inbox e JOIN agent_event_sources s ON s.id=e.sourceID
                WHERE s.kind='calendar' AND e.handledAt IS NULL AND (e.key LIKE 'meeting:%' OR e.key LIKE 'daily:%' OR e.key LIKE 'weekly:%')
                """)
                for event in pending {
                    if event.key?.hasPrefix("meeting:") == false {
                        if selected.isEmpty { try event.delete(db) }
                    } else {
                        let ref = event.ref.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
                        if let provider = ref?.objectValue?["provider"]?.stringValue, !selected.contains(provider) {
                            try event.delete(db)
                        }
                    }
                }
            }
            // Eligibility applies to retained signals even when generation is paused.
            let sources = try AgentSourceRecord.fetchAll(db, sql: "SELECT * FROM agent_event_sources WHERE kind='calendar'")
            for var source in sources {
                let options = source.sourceOptions
                var agendas: [AgentEventRecord] = []
                var meetings: [AgentEventRecord] = []
                if source.enabled, !successful.isEmpty, let daily = source.dailyAt,
                   let components = Self.dailyComponents(daily),
                   let at = calendar.date(bySettingHour: components.hour, minute: components.minute, second: 0, of: now) {
                    let day = calendar.dateComponents([.year, .month, .day], from: now)
                    let date = String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!)
                    agendas.append(AgentEventRecord(
                        id: UUID.v7().uuidString, agentID: source.agentID, sourceID: source.id, key: "daily:" + date, topic: nil,
                        note: AgentSourcePrompt.dailyNote(source), ref: "{\"date\":\"\(date)\"}", occurredAt: at,
                        taskID: nil, handledAt: nil, createdAt: now
                    ))
                }
                // Only on its weekday, so a week whose day passed while the app was closed gets no late signal.
                if source.enabled, !successful.isEmpty, let weekly = options.weeklyAt, calendar.component(.weekday, from: now) == options.weekday,
                   let components = Self.dailyComponents(weekly),
                   let at = calendar.date(bySettingHour: components.hour, minute: components.minute, second: 0, of: now) {
                    var iso = Calendar(identifier: .iso8601)
                    iso.timeZone = calendar.timeZone
                    let week = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
                    let key = String(format: "%04d-W%02d", week.yearForWeekOfYear!, week.weekOfYear!)
                    agendas.append(AgentEventRecord(
                        id: UUID.v7().uuidString, agentID: source.agentID, sourceID: source.id, key: "weekly:" + key, topic: nil,
                        note: AgentSourcePrompt.weeklyNote(source), ref: "{\"week\":\"\(key)\"}", occurredAt: at,
                        taskID: nil, handledAt: nil, createdAt: now
                    ))
                }
                var meetingKeys: Set<String> = []
                for event in snapshot.events where successful.contains(AgentCalendarSnapshot.provider(for: event))
                    && event.startDate > now && !event.isAllDay && !event.isDeclined && (options.acceptedOnly != true || event.isAttending) {
                    let key = "meeting:\(event.displayID):\(event.startDate.ISO8601Format())"
                    meetingKeys.insert(key)
                    // Turning off notifications preserves arrived signals for meetings that are still valid.
                    guard source.enabled, let lead = source.leadHours else { continue }
                    var fields: [String: JSONValue] = [
                        "provider": .string(AgentCalendarSnapshot.provider(for: event)), "calendar_id": .string(event.calendarID),
                        "event_id": .string(event.platformId), "start": .string(event.startDate.ISO8601Format()),
                    ]
                    // Google gives the event's web page; Apple Calendar events have none to open.
                    if let url = event.url { fields["url"] = .string(url.absoluteString) }
                    let ref = JSONValue.object(fields)
                    try meetings.append(AgentEventRecord(
                        id: UUID.v7().uuidString, agentID: source.agentID, sourceID: source.id, key: key, topic: nil,
                        note: L10n.agentCalendarMeetingNote(event.title), ref: String(decoding: JSONEncoder().encode(ref), as: UTF8.self),
                        occurredAt: event.startDate.addingTimeInterval(-lead * 3600), taskID: nil, handledAt: nil, createdAt: now
                    ))
                }
                let pending = try AgentEventRecord.fetchAll(db, sql: """
                SELECT * FROM agent_event_inbox WHERE sourceID=? AND handledAt IS NULL AND key LIKE 'meeting:%'
                """, arguments: [source.id])
                for event in pending {
                    let ref = event.ref.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
                    if let provider = ref?.objectValue?["provider"]?.stringValue,
                       successful.contains(provider), !meetingKeys.contains(event.key ?? "") {
                        try event.delete(db)
                    }
                }
                var recorded = 0
                if source.enabled, !successful.isEmpty {
                    recorded = try Self.reconcileAgendaReservations(agendas, sourceID: source.id, now: now, db: db)
                }
                for event in meetings {
                    if var existing = try AgentEventRecord.fetchOne(
                        db,
                        sql: "SELECT * FROM agent_event_inbox WHERE sourceID=? AND key=?",
                        arguments: [source.id, event.key]
                    ) {
                        if existing.handledAt == nil {
                            existing.occurredAt = event.occurredAt
                            existing.ref = event.ref
                            existing.note = event.note
                            try existing.update(db)
                        }
                    } else {
                        try event.insert(db)
                        recorded += 1
                    }
                }
                if source.enabled, !successful.isEmpty {
                    source.lastReadCount = snapshot.events.count
                    source.lastRecordedCount = recorded
                    source.lastIntakeAt = now
                    try source.update(db)
                }
            }
        }
    }

    /// Only future reservations follow the current local schedule; arrived decisions and handled history are durable.
    private static func reconcileAgendaReservations(_ candidates: [AgentEventRecord], sourceID: String, now: Date, db: Database) throws -> Int {
        let reservations = try AgentEventRecord.fetchAll(db, sql: """
        SELECT * FROM agent_event_inbox WHERE sourceID=? AND handledAt IS NULL AND occurredAt>?
        AND (key LIKE 'daily:%' OR key LIKE 'weekly:%')
        """, arguments: [sourceID, now])
        for reservation in reservations {
            if let candidate = candidates.first(where: { $0.key == reservation.key }) {
                try db.execute(sql: "UPDATE agent_event_inbox SET occurredAt=? WHERE id=?", arguments: [candidate.occurredAt, reservation.id])
            } else {
                try reservation.delete(db)
            }
        }
        var recorded = 0
        for candidate in candidates {
            // The unique date/week key also prevents reissuing an arrived or handled occurrence.
            try candidate.insert(db, onConflict: .ignore)
            recorded += db.changesCount
        }
        return recorded
    }

    static func dailyComponents(_ value: String) -> (hour: Int, minute: Int)? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// The agent can also close this event by ID before its time if the user cancels the reminder.
    @discardableResult
    func remind(at: Date, note: String, now: Date = .now) throws -> String {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard at > now, !note.isEmpty, note.count <= Self.noteLimit else {
            throw Failure(message: "A reminder needs a future time and a note of 1 to 500 characters.")
        }
        let event = AgentEventRecord(
            id: UUID.v7().uuidString,
            agentID: agentID,
            sourceID: nil,
            key: nil,
            topic: nil,
            note: note,
            ref: nil,
            occurredAt: at,
            taskID: nil,
            handledAt: nil,
            createdAt: now
        )
        try dbQueue.write { try event.insert($0) }
        return event.id
    }
}
