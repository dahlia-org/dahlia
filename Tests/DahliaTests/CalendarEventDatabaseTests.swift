import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CalendarEventDatabaseTests {
        @Test
        func initializesCalendarEventIdentitySchema() throws {
            let database = try AppDatabaseManager(path: ":memory:")

            let schema = try database.dbQueue.read { db in
                try (
                    String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('calendar_events') ORDER BY cid"),
                    String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('calendar_events') WHERE pk > 0 ORDER BY pk"),
                    String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('meetings')"),
                    db.tableExists("calendar_event_sources"),
                    String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('calendar_event_sources')"),
                    String.fetchAll(db, sql: "SELECT name FROM pragma_index_info('meetings_on_calendar_event') ORDER BY seqno")
                )
            }

            #expect(schema.0.contains("ical_uid"))
            #expect(schema.0.contains("recurrence_id"))
            #expect(schema.0.contains("description"))
            #expect(schema.0.contains("conference_uri"))
            #expect(schema.0.contains("url"))
            #expect(!schema.0.contains("id"))
            #expect(schema.1 == ["ical_uid", "recurrence_id"])
            #expect(schema.2.contains("calendar_event_ical_uid"))
            #expect(schema.2.contains("calendar_event_recurrence_id"))
            #expect(schema.3)
            #expect(!schema.4.contains("source_event_url"))
            #expect(schema.5 == [
                "vaultId",
                "calendar_event_ical_uid",
                "calendar_event_recurrence_id",
                "createdAt",
                "id",
            ])
        }

        @Test
        func meetingCalendarReferenceRejectsIncompleteAndMissingKeys() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/calendar-reference-test",
                name: "Calendar Reference Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            try database.dbQueue.write { db in
                try vault.insert(db)
            }

            #expect(throws: Error.self) {
                try insertMeeting(
                    named: "Incomplete",
                    vaultId: vault.id,
                    calendarUID: "event@example.com",
                    recurrenceId: nil,
                    in: database.dbQueue
                )
            }
            #expect(throws: Error.self) {
                try insertMeeting(
                    named: "Missing",
                    vaultId: vault.id,
                    calendarUID: "missing@example.com",
                    recurrenceId: "",
                    in: database.dbQueue
                )
            }
        }

        @Test
        func uidAndRecurrenceIdFormTheCalendarEventPrimaryKey() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let first = calendarEvent(recurrenceId: "20260417T003000Z")
            let second = calendarEvent(recurrenceId: "20260424T003000Z")

            try database.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: first, now: .now, in: db)
                try CalendarEventRecord.upsert(event: second, now: .now, in: db)
            }

            let count = try database.dbQueue.read { db in
                try CalendarEventRecord.fetchCount(db)
            }
            #expect(count == 2)

            let firstKey = try #require(first.key)
            #expect(throws: Error.self) {
                try database.dbQueue.write { db in
                    try CalendarEventRecord(now: .now, event: first, key: firstKey).insert(db)
                }
            }
        }

        @Test
        func upsertWithoutURLPreservesExistingCalendarEventURL() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let eventURL = try #require(URL(string: "https://calendar.google.com/calendar/event?eid=planning"))
            let withURL = calendarEvent(recurrenceId: "", url: eventURL)
            let withoutURL = calendarEvent(recurrenceId: "")
            let key = try #require(withURL.key)

            let persisted = try database.dbQueue.write { db in
                try CalendarEventRecord.upsert(event: withURL, now: .now, in: db)
                try CalendarEventRecord.upsert(event: withoutURL, now: .now, in: db)
                return try CalendarEventRecord.fetch(key: key, in: db)
            }

            #expect(persisted?.url == eventURL.absoluteString)
        }

        @Test
        func meetingLookupIsScopedToTheActiveVault() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let activeVault = VaultRecord(
                id: .v7(),
                path: "/tmp/calendar-active-vault",
                name: "Active Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let otherVault = VaultRecord(
                id: .v7(),
                path: "/tmp/calendar-other-vault",
                name: "Other Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let event = calendarEvent(recurrenceId: "")
            let key = try #require(event.key)
            let activeMeetingId = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let tiedActiveMeetingId = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
            let otherMeetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)

            try database.dbQueue.write { db in
                try activeVault.insert(db)
                try otherVault.insert(db)
                try CalendarEventRecord.upsert(event: event, now: createdAt, in: db)
                try insertCalendarMeeting(
                    id: activeMeetingId,
                    named: "Active vault meeting",
                    vaultId: activeVault.id,
                    createdAt: createdAt,
                    key: key,
                    in: db
                )
                try insertCalendarMeeting(
                    id: otherMeetingId,
                    named: "Newer meeting in another vault",
                    vaultId: otherVault.id,
                    createdAt: createdAt.addingTimeInterval(60),
                    key: key,
                    in: db
                )
                try insertCalendarMeeting(
                    id: tiedActiveMeetingId,
                    named: "Deterministic tie winner",
                    vaultId: activeVault.id,
                    createdAt: createdAt,
                    key: key,
                    in: db
                )
            }

            let repository = MeetingRepository(dbQueue: database.dbQueue)
            #expect(
                try repository.resolveMeetingIdForCalendarEvent(event, vaultId: activeVault.id)
                    == tiedActiveMeetingId
            )
            #expect(
                try repository.resolveMeetingIdForCalendarEvent(event, vaultId: otherVault.id)
                    == otherMeetingId
            )
        }

        @Test
        func migrationPreservesMeetingsAndDiscardsLegacyCalendarRows() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: UUID().uuidString)
                .appendingPathExtension("sqlite")
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)
            defer { try? FileManager.default.removeItem(at: databaseURL) }

            try prepareLegacyV14Database(
                at: databaseURL,
                meetingId: meetingId,
                createdAt: createdAt
            )

            let migrated = try AppDatabaseManager(path: databaseURL.path)
            let result = try migrated.dbQueue.read { db in
                try (
                    MeetingRecord.fetchOne(db, key: meetingId),
                    CalendarEventRecord.fetchCount(db)
                )
            }

            let meeting = try #require(result.0)
            #expect(meeting.name == "Keep me")
            #expect(meeting.calendarEventIcalUid == nil)
            #expect(meeting.calendarEventRecurrenceId == nil)
            #expect(result.1 == 0)
        }

        @Test
        func migrationMovesURLAndNormalizesDateRecurrenceId() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: UUID().uuidString)
                .appendingPathExtension("sqlite")
            let eventURL = "https://calendar.google.com/calendar/event?eid=planning"
            defer { try? FileManager.default.removeItem(at: databaseURL) }

            try prepareLegacyV15Database(at: databaseURL, eventURL: eventURL)

            let migrated = try AppDatabaseManager(path: databaseURL.path)
            let result = try migrated.dbQueue.read { db in
                try (
                    CalendarEventRecord.fetch(
                        key: CalendarEventKey(icalUid: "planning@google.com", recurrenceId: "20260417"),
                        in: db
                    ),
                    String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('calendar_event_sources')")
                )
            }

            #expect(result.0?.url == eventURL)
            #expect(!result.1.contains("source_event_url"))
        }
    }

    private func insertMeeting(
        named name: String,
        vaultId: UUID,
        calendarUID: String?,
        recurrenceId: String?,
        in dbQueue: DatabaseQueue
    ) throws {
        try dbQueue.write { db in
            try MeetingRecord(
                id: .v7(),
                vaultId: vaultId,
                projectId: nil,
                name: name,
                createdAt: .now,
                updatedAt: .now,
                calendarEventIcalUid: calendarUID,
                calendarEventRecurrenceId: recurrenceId
            ).insert(db)
        }
    }

    private func insertCalendarMeeting(
        id: UUID,
        named name: String,
        vaultId: UUID,
        createdAt: Date,
        key: CalendarEventKey,
        in db: Database
    ) throws {
        try MeetingRecord(
            id: id,
            vaultId: vaultId,
            projectId: nil,
            name: name,
            createdAt: createdAt,
            updatedAt: createdAt,
            calendarEventIcalUid: key.icalUid,
            calendarEventRecurrenceId: key.recurrenceId
        ).insert(db)
    }

    private func calendarEvent(
        recurrenceId: String,
        url: URL? = nil
    ) -> CalendarEvent {
        let start = Date(timeIntervalSince1970: 1_776_384_000)
        return CalendarEvent(
            id: "google::\(recurrenceId)",
            calendarID: "primary",
            calendarName: "Primary",
            calendarColorHex: nil,
            platform: CalendarEventPlatform.googleCalendar,
            platformId: recurrenceId,
            title: "Planning",
            description: "",
            icalUid: "series@example.com",
            recurrenceId: recurrenceId,
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            isAllDay: false,
            conferenceURI: nil,
            url: url
        )
    }

    private func prepareLegacyV15Database(at databaseURL: URL, eventURL: String) throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try createLegacyV15CalendarTables(in: db)
            try markMigrationsThroughV14Applied(in: db)
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["v15_calendarEventIdentity"]
            )
            try insertLegacyV15CalendarEvent(eventURL: eventURL, in: db)
        }
    }

    private func createLegacyV15CalendarTables(in db: Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE calendar_events (
                ical_uid TEXT NOT NULL,
                recurrence_id TEXT NOT NULL DEFAULT '',
                created_at DATETIME NOT NULL,
                updated_at DATETIME NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                description TEXT NOT NULL DEFAULT '',
                start DATETIME NOT NULL,
                "end" DATETIME NOT NULL,
                is_all_day BOOLEAN NOT NULL DEFAULT 0,
                conference_uri TEXT,
                PRIMARY KEY (ical_uid, recurrence_id)
            ) WITHOUT ROWID
            """
        )
        try db.execute(
            sql: """
            CREATE TABLE calendar_event_sources (
                platform TEXT NOT NULL,
                calendar_id TEXT NOT NULL,
                platform_id TEXT NOT NULL,
                ical_uid TEXT NOT NULL,
                recurrence_id TEXT NOT NULL,
                source_event_url TEXT,
                created_at DATETIME NOT NULL,
                updated_at DATETIME NOT NULL,
                PRIMARY KEY (platform, calendar_id, platform_id),
                FOREIGN KEY (ical_uid, recurrence_id)
                    REFERENCES calendar_events (ical_uid, recurrence_id)
                    ON UPDATE CASCADE
                    ON DELETE CASCADE
            ) WITHOUT ROWID
            """
        )
        try db.create(table: "grdb_migrations") { table in
            table.column("identifier", .text).primaryKey()
        }
    }

    private func insertLegacyV15CalendarEvent(eventURL: String, in db: Database) throws {
        let now = Date(timeIntervalSince1970: 1_776_384_000)
        try db.execute(
            sql: """
            INSERT INTO calendar_events (
                ical_uid, recurrence_id, created_at, updated_at, title, description,
                start, "end", is_all_day, conference_uri
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "planning@google.com", "VALUE=DATE:20260417", now, now, "Planning", "", now,
                now.addingTimeInterval(3600), false, nil,
            ]
        )
        try db.execute(
            sql: """
            INSERT INTO calendar_event_sources (
                platform, calendar_id, platform_id, ical_uid, recurrence_id,
                source_event_url, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                CalendarEventPlatform.googleCalendar, "primary", "planning",
                "planning@google.com", "VALUE=DATE:20260417", eventURL, now, now,
            ]
        )
    }

    private func prepareLegacyV14Database(
        at databaseURL: URL,
        meetingId: UUID,
        createdAt: Date
    ) throws {
        let queue = try DatabaseQueue(path: databaseURL.path)
        try queue.write { db in
            try createLegacyCalendarTables(in: db)
            try markMigrationsThroughV14Applied(in: db)
            try insertLegacyMeetingAndCalendarEvent(meetingId: meetingId, createdAt: createdAt, in: db)
        }
    }

    private func createLegacyCalendarTables(in db: Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE meetings (
                id BLOB PRIMARY KEY,
                vaultId BLOB NOT NULL,
                projectId BLOB,
                name TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT 'READY',
                duration DOUBLE,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL
            )
            """
        )
        try db.execute(
            sql: """
            CREATE TABLE calendar_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meetingId BLOB NOT NULL UNIQUE,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL,
                platform TEXT NOT NULL,
                platformId TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                icalUid TEXT,
                start DATETIME NOT NULL,
                "end" DATETIME NOT NULL,
                meetingUrl TEXT,
                UNIQUE(platform, platformId)
            )
            """
        )
        try db.create(table: "grdb_migrations") { table in
            table.column("identifier", .text).primaryKey()
        }
    }

    private func markMigrationsThroughV14Applied(in db: Database) throws {
        for migration in [
            "v3_googleDriveFolderSchema",
            "v4_instructionsSchema",
            "v5_summaryGoogleFileId",
            "v6_transcriptSegmentTranslation",
            "v7_normalizeLegacyMeetingStatus",
            "v8_recordingSessions",
            "v9_summaryDocument",
            "v10_batchTranscription",
            "v11_batchAudioStorageLocation",
            "v12_batchTranscriptionDiscard",
            "v13_summaryVaultRelativePath",
            "v14_projectDescription",
        ] {
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: [migration]
            )
        }
    }

    private func insertLegacyMeetingAndCalendarEvent(
        meetingId: UUID,
        createdAt: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO meetings (id, vaultId, name, status, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [meetingId, UUID.v7(), "Keep me", MeetingStatus.ready.rawValue, createdAt, createdAt]
        )
        try db.execute(
            sql: """
            INSERT INTO calendar_events (
                meetingId, createdAt, updatedAt, platform, platformId, description, icalUid, start, "end", meetingUrl
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                meetingId,
                createdAt,
                createdAt,
                CalendarEventPlatform.googleCalendar,
                "legacy-event",
                "Discard me",
                "legacy@example.com",
                createdAt,
                createdAt.addingTimeInterval(3600),
                "https://meet.example.com/legacy",
            ]
        )
    }
#endif
