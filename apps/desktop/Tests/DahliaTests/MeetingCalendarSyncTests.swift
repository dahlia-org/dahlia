#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct MeetingCalendarSyncTests {
        @Test(arguments: ["cleared", "reassigned", "rescheduled"])
        func canonicalCalendarSurvivesRenameAndRecreation(change: String) throws {
            let (database, vault, meeting) = try fixture()
            let calendar: [String: Any] = change == "cleared"
                ? ["icalUid": NSNull(), "recurrenceId": NSNull(), "calendarEvent": NSNull()]
                : [
                    "icalUid": change == "reassigned" ? "remote@example.com" : "event@example.com",
                    "recurrenceId": "",
                    "calendarEvent": ["start": "2026-09-12T10:00:00+09:00", "end": "2026-09-12T11:00:00+09:00", "is_all_day": false],
                ]
            try database.dbQueue.write { db in
                var body = try payload(SyncInitialSnapshotBuilder.meetingOperation(meeting, action: .create, in: db))
                body.merge(calendar) { _, remote in remote }
                let canonical = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: JSONSerialization.data(withJSONObject: body))
                try SyncTransactionQueue.applyCanonical(.meeting, id: meeting.id, vaultId: vault.id, value: canonical, remoteRevision: 2, in: db)
                var renamed = try #require(try MeetingRecord.fetchOne(db, key: meeting.id))
                #expect(renamed.calendarEventIcalUid == "event@example.com")
                #expect(renamed.calendarEventRecurrenceId?.isEmpty == true)
                renamed.name = "Renamed"
                try renamed.update(db)
                for action in [SyncAction.update, .create] {
                    let sent = try payload(SyncInitialSnapshotBuilder.meetingOperation(renamed, action: action, in: db))
                    for key in ["icalUid", "recurrenceId", "calendarEvent"] {
                        #expect(try NSDictionary(dictionary: [key: #require(sent[key])]) ==
                            NSDictionary(dictionary: [key: #require(calendar[key])]))
                    }
                }
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") == 0)
            }
        }

        @Test
        func calendarRefreshQueuesLinkedOwnersAndPreservesNewerChangesAcrossReceipt() async throws {
            let (database, vault, meeting) = try fixture()
            let secondID = UUID.v7(), clearedID = UUID.v7(), localID = UUID.v7(), memberID = UUID.v7()
            try await database.dbQueue.write { db in
                var second = meeting
                second.id = secondID
                try second.insert(db)
                var cleared = meeting
                cleared.id = clearedID
                try cleared.insert(db)
                try MeetingCalendarSync(icalUid: nil, recurrenceId: nil, calendarEvent: nil).save(meetingId: cleared.id, in: db)
                for member in [false, true] {
                    var otherVault = vault
                    otherVault.id = .v7()
                    otherVault.path = "/tmp/calendar-\(otherVault.id)"
                    otherVault.syncRole = member ? "member" : nil
                    if !member {
                        otherVault.accountConnectionId = nil
                        otherVault.syncConfirmedConnectionId = nil
                    }
                    try otherVault.insert(db)
                    var otherMeeting = meeting
                    otherMeeting.id = member ? memberID : localID
                    otherMeeting.vaultId = otherVault.id
                    try otherMeeting.insert(db)
                    if !member {
                        // A detached Local copy retains the last canonical calendar snapshot.
                        let original = try #require(try CalendarEventRecord.fetch(
                            key: CalendarEventKey(icalUid: "event@example.com", recurrenceId: ""), in: db
                        ))
                        try MeetingCalendarSync(
                            icalUid: original.icalUid, recurrenceId: original.recurrenceId, calendarEvent: .init(original)
                        ).save(meetingId: localID, in: db)
                    }
                }
                try CalendarEventRecord.upsert(event: event(start: 3600, end: 10800, allDay: true), now: .now, in: db)
                // Re-observation with no snapshot change must not add another transaction.
                try CalendarEventRecord.upsert(event: event(start: 3600, end: 10800, allDay: true), now: .now, in: db)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") == 1)
            }
            let first = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(Set(first.operations.map(\.entityId)) == [meeting.id, secondID])
            try await database.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: event(start: 7200, end: 14400, allDay: false), now: .now, in: db)
            }
            let records = try first.operations.map { operation in
                let data = try #require(operation.payloadJSON)
                var body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                body["createdAt"] = meeting.createdAt.ISO8601Format()
                return try SyncTransactionResponse.Record(
                    entity: .meeting, id: operation.entityId, revision: 1,
                    record: SyncJSON.decoder.decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: body))
                )
            }
            try await SyncTransactionQueue.complete(
                first, response: .init(id: first.id, status: "committed", cursor: "1", records: records), dbQueue: database.dbQueue
            )
            let next = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(Set(next.operations.map(\.entityId)) == [meeting.id, secondID])
            try await database.dbQueue.read { db in
                for id in [meeting.id, secondID, localID] {
                    let current = try #require(try MeetingCalendarSync.fetch(meetingId: id, in: db))
                    #expect(current.calendarEvent?.start == Date(timeIntervalSince1970: 7200).ISO8601Format())
                    #expect(current.calendarEvent?.end == Date(timeIntervalSince1970: 14400).ISO8601Format())
                    #expect(current.calendarEvent?.isAllDay == false)
                }
                #expect(try MeetingCalendarSync.fetch(meetingId: memberID, in: db) == nil)
                let cleared = try #require(try MeetingCalendarSync.fetch(meetingId: clearedID, in: db))
                #expect(cleared.icalUid == nil && cleared.calendarEvent == nil)
            }
        }

        @Test
        func migrationPreservesExistingMeetingAndLocalCalendarReference() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v42_localFirstSchema")
            let vaultID = UUID.v7(), meetingID = UUID.v7()
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO vaults(id, name, createdAt, lastOpenedAt) VALUES (?, 'Vault', 1, 1);
                INSERT INTO calendar_events(ical_uid, recurrence_id, created_at, updated_at, title, start, "end", is_all_day)
                VALUES ('event@example.com', '', 1, 1, 'Event', 1, 2, 0);
                INSERT INTO meetings(id, vaultId, name, status, createdAt, updatedAt, calendar_event_ical_uid, calendar_event_recurrence_id)
                VALUES (?, ?, 'Preserved', 'READY', 1, 1, 'event@example.com', '');
                """, arguments: [vaultID, meetingID, vaultID])
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db in
                let meeting = try #require(try MeetingRecord.fetchOne(db, key: meetingID))
                #expect(meeting.name == "Preserved" && meeting.calendarEventIcalUid == "event@example.com")
                #expect(try MeetingCalendarSync.fetch(meetingId: meetingID, in: db) == nil)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        private nonisolated func payload(_ operation: SyncOperationDraft) throws -> [String: Any] {
            let data = try #require(operation.payloadJSON)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        private nonisolated func event(start: TimeInterval = 0, end: TimeInterval = 3600, allDay: Bool = false) -> CalendarEvent {
            CalendarEvent(
                id: "event", calendarID: "calendar", calendarName: "Calendar", calendarColorHex: nil,
                platformId: "event", title: "Event", description: "", icalUid: "event@example.com",
                startDate: Date(timeIntervalSince1970: start), endDate: Date(timeIntervalSince1970: end),
                isAllDay: allDay, conferenceURI: nil
            )
        }

        private func fixture() throws -> (AppDatabaseManager, VaultRecord, MeetingRecord) {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://server.example.com", clientID: "desktop", createdAt: .now)
            var vault = VaultRecord(id: .v7(), path: "/tmp/calendar-sync", name: "Sync", createdAt: .now, lastOpenedAt: .now)
            vault.accountConnectionId = connection.id
            vault.syncConfirmedConnectionId = connection.id
            let meeting = MeetingRecord(
                id: .v7(), vaultId: vault.id, name: "Meeting", createdAt: .now, updatedAt: .now,
                calendarEventIcalUid: "event@example.com", calendarEventRecurrenceId: ""
            )
            try database.dbQueue.write { db in
                try connection.insert(db)
                try vault.insert(db)
                try CalendarEventRecord.upsert(event: event(), now: .now, in: db)
                try meeting.insert(db)
            }
            return (database, vault, meeting)
        }
    }
#endif
