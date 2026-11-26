import DahliaRuntimeSupport
import Foundation
import GRDB

extension AgentInboxService {
    /// Deselected providers cancel pending signals; selected providers retain theirs across temporary fetch failures.
    func reconcileCalendar(_ snapshot: AgentCalendarSnapshot, now: Date = .now, calendar: Calendar = .current) throws {
        let successful = snapshot.successfulProviders.intersection(snapshot.selectedProviders ?? snapshot.successfulProviders)
        try dbQueue.write { db in
            let sources = try AgentSourceRecord.fetchAll(db, sql: "SELECT * FROM agent_event_sources WHERE enabled=1 AND kind='calendar'")
            for var source in sources {
                var desired: [AgentEventRecord] = []
                if !successful.isEmpty, let daily = source.dailyAt,
                   let components = Self.dailyComponents(daily),
                   let at = calendar.date(bySettingHour: components.hour, minute: components.minute, second: 0, of: now) {
                    let day = calendar.dateComponents([.year, .month, .day], from: now)
                    let date = String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!)
                    desired.append(AgentEventRecord(
                        id: UUID.v7().uuidString, sourceID: source.id, key: "daily:" + date, topic: nil,
                        note: L10n.agentCalendarDailyNote, ref: "{\"date\":\"\(date)\"}", occurredAt: at,
                        taskID: nil, handledAt: nil, createdAt: now
                    ))
                }
                var meetingKeys: Set<String> = []
                for event in snapshot.events where successful.contains(AgentCalendarSnapshot.provider(for: event))
                    && event.startDate > now && !event.isAllDay && !event.isDeclined {
                    let key = "meeting:\(event.displayID):\(event.startDate.ISO8601Format())"
                    meetingKeys.insert(key)
                    // Turning off notifications preserves arrived signals for meetings that are still valid.
                    guard let lead = source.leadHours else { continue }
                    let ref = JSONValue.object([
                        "provider": .string(AgentCalendarSnapshot.provider(for: event)), "calendar_id": .string(event.calendarID),
                        "event_id": .string(event.platformId), "start": .string(event.startDate.ISO8601Format()),
                    ])
                    try desired.append(AgentEventRecord(
                        id: UUID.v7().uuidString, sourceID: source.id, key: key, topic: nil,
                        note: L10n.agentCalendarMeetingNote, ref: String(decoding: JSONEncoder().encode(ref), as: UTF8.self),
                        occurredAt: event.startDate.addingTimeInterval(-lead * 3600), taskID: nil, handledAt: nil, createdAt: now
                    ))
                }
                let pending = try AgentEventRecord.fetchAll(db, sql: """
                SELECT * FROM agent_event_inbox WHERE sourceID=? AND handledAt IS NULL AND (key LIKE 'meeting:%' OR key LIKE 'daily:%')
                """, arguments: [source.id])
                for event in pending {
                    if event.key?.hasPrefix("daily:") == true {
                        if snapshot.selectedProviders?.isEmpty == true { try event.delete(db) }
                        continue
                    }
                    let ref = event.ref.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
                    if let provider = ref?.objectValue?["provider"]?.stringValue {
                        let deselected = snapshot.selectedProviders.map { !$0.contains(provider) } ?? false
                        if deselected || (successful.contains(provider) && !meetingKeys.contains(event.key ?? "")) {
                            try event.delete(db)
                        }
                    }
                }
                var recorded = 0
                for event in desired {
                    if var existing = try AgentEventRecord.fetchOne(
                        db,
                        sql: "SELECT * FROM agent_event_inbox WHERE sourceID=? AND key=?",
                        arguments: [source.id, event.key]
                    ) {
                        if existing.handledAt == nil {
                            existing.occurredAt = event.occurredAt
                            existing.ref = event.ref
                            try existing.update(db)
                        }
                    } else {
                        try event.insert(db)
                        recorded += 1
                    }
                }
                if !successful.isEmpty {
                    source.lastReadCount = snapshot.events.count
                    source.lastRecordedCount = recorded
                    source.lastIntakeAt = now
                    try source.update(db)
                }
            }
        }
    }

    static func dailyComponents(_ value: String) -> (hour: Int, minute: Int)? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0 ... 23).contains(hour), (0 ... 59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// The bot can also close this event by ID before its time if the user cancels the reminder.
    @discardableResult
    func remind(at: Date, note: String, now: Date = .now) throws -> String {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard at > now, !note.isEmpty, note.count <= Self.noteLimit else {
            throw Failure(message: "A reminder needs a future time and a note of 1 to 500 characters.")
        }
        let event = AgentEventRecord(
            id: UUID.v7().uuidString,
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
