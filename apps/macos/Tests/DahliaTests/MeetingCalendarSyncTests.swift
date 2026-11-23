#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct MeetingCalendarSyncTests {

        @Test
        func migrationPreservesExistingMeetingAndLocalCalendarReference() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v42_localFirstSchema")
            let workspaceID = UUID.v7(), meetingID = UUID.v7()
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO workspaces(id, name, createdAt, lastOpenedAt) VALUES (?, 'Workspace', 1, 1);
                INSERT INTO calendar_events(ical_uid, recurrence_id, created_at, updated_at, title, start, "end", is_all_day)
                VALUES ('event@example.com', '', 1, 1, 'Event', 1, 2, 0);
                INSERT INTO meetings(id, workspace_id, name, status, createdAt, updatedAt, calendar_event_ical_uid, calendar_event_recurrence_id)
                VALUES (?, ?, 'Preserved', 'READY', 1, 1, 'event@example.com', '');
                """, arguments: [workspaceID, meetingID, workspaceID])
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db in
                let meeting = try #require(try MeetingRecord.fetchOne(db, key: meetingID))
                #expect(meeting.name == "Preserved" && meeting.calendarEventIcalUid == "event@example.com")
                #expect(try MeetingCalendarSync.fetch(meetingId: meetingID, in: db) == nil)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

    }
#endif
