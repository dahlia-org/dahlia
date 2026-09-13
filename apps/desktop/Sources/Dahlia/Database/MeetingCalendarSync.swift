import Foundation
import GRDB

/// The synchronized working copy is separate from this Mac's calendar references.
struct MeetingCalendarSync: Codable, Equatable, Sendable {
    struct Event: Codable, Equatable, Sendable {
        var start: String
        var end: String
        var isAllDay: Bool
        var attendees: [CalendarAttendeeSnapshot]?

        enum CodingKeys: String, CodingKey {
            case start, end
            case isAllDay = "is_all_day"
            case attendees
        }

        init(_ event: CalendarEventRecord) {
            start = event.start.ISO8601Format()
            end = event.end.ISO8601Format()
            isAllDay = event.isAllDay
            attendees = event.attendees
        }
    }

    var icalUid: String?
    var recurrenceId: String?
    var calendarEvent: Event?

    var payload: [String: Any] {
        [
            "icalUid": icalUid as Any? ?? NSNull(),
            "recurrenceId": recurrenceId as Any? ?? NSNull(),
            "calendarEvent": calendarEvent.map {
                var event: [String: Any] = [
                    "start": $0.start,
                    "end": $0.end,
                    "is_all_day": $0.isAllDay,
                ]
                if let attendees = $0.attendees {
                    event["attendees"] = attendees.map {
                        ["email": $0.email, "display_name": $0.displayName as Any? ?? NSNull()]
                    }
                }
                return event
            } as Any? ?? NSNull(),
        ]
    }

    static func fetch(meetingId: UUID, in db: Database) throws -> Self? {
        try Data.fetchOne(db, sql: "SELECT calendarSyncMetadata FROM meetings WHERE id = ?", arguments: [meetingId])
            .map { try SyncJSON.decoder.decode(Self.self, from: $0) }
    }

    func save(meetingId: UUID, in db: Database) throws {
        try db.execute(
            sql: "UPDATE meetings SET calendarSyncMetadata = ? WHERE id = ?",
            arguments: [SyncJSON.encoder.encode(self), meetingId]
        )
    }

    static func recordChange(from previous: CalendarEventRecord?, to event: CalendarEventRecord, in db: Database) throws {
        guard previous.map(Event.init) != Event(event) else { return }
        let meetings = try MeetingRecord.fetchAll(db, sql: """
        SELECT meetings.* FROM meetings JOIN vaults ON vaults.id = meetings.vaultId
        WHERE meetings.calendar_event_ical_uid = ? AND meetings.calendar_event_recurrence_id = ?
            AND (vaults.accountConnectionId IS NULL OR vaults.syncRole IN ('admin', 'editor'))
        """, arguments: [event.icalUid, event.recurrenceId])
        let updated = Self(icalUid: event.icalUid, recurrenceId: event.recurrenceId, calendarEvent: Event(event))
        for (vaultId, meetings) in Dictionary(grouping: meetings, by: \.vaultId) {
            var operations: [SyncOperationDraft] = []
            for meeting in meetings {
                if let current = try fetch(meetingId: meeting.id, in: db) {
                    // A local calendar refresh must not restore a remotely cleared or reassigned identity.
                    guard current.icalUid == event.icalUid, current.recurrenceId == event.recurrenceId,
                          current != updated else { continue }
                }
                try updated.save(meetingId: meeting.id, in: db)
                try operations.append(SyncInitialSnapshotBuilder.meetingOperation(meeting, action: .update, in: db))
            }
            try SyncTransactionRecorder.recordBatches(vaultId: vaultId, operations: operations, in: db)
        }
    }
}
