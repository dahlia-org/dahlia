import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
import Testing

@MainActor
struct AppDatabaseManagerTests {
    @Test
    func initializesInMemoryDatabaseWithGoogleDriveFolderColumn() throws {
        let database = try AppDatabaseManager(path: ":memory:")

        let columns = try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('projects')")
        }

        #expect(columns.contains("googleDriveFolderId"))
    }

    @Test
    func initializesInMemoryDatabaseWithSummaryGoogleFileIdColumn() throws {
        let database = try AppDatabaseManager(path: ":memory:")

        let columns = try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summaries')")
        }

        #expect(columns.contains("googleFileId"))
    }

    @Test
    func initializesInMemoryDatabaseWithSummaryDocumentColumn() throws {
        let database = try AppDatabaseManager(path: ":memory:")

        let columns = try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summaries')")
        }

        #expect(columns.contains("document"))
    }

    @Test
    func initializesInMemoryDatabaseWithTranscriptTranslatedTextColumn() throws {
        let database = try AppDatabaseManager(path: ":memory:")

        let columns = try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('transcript_segments')")
        }

        #expect(columns.contains("translatedText"))
    }

    @Test
    func initializesInMemoryDatabaseWithRecordingSessionsSchema() throws {
        let database = try AppDatabaseManager(path: ":memory:")

        let result = try database.dbQueue.read { db in
            try (
                db.tableExists("recording_sessions"),
                String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('transcript_segments')"),
                String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('screenshots')")
            )
        }

        #expect(result.0)
        #expect(result.1.contains("sessionId"))
        #expect(result.2.contains("sessionId"))
    }

    @Test
    func existingV7DatabaseBackfillsRecordingSessionsWithoutDataLoss() throws {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        let meetingID = UUID.v7()
        let segmentID = UUID.v7()
        let screenshotID = UUID.v7()
        let meetingStart = Date(timeIntervalSince1970: 1_776_384_000)
        let segmentStart = meetingStart.addingTimeInterval(5)
        let segmentEnd = meetingStart.addingTimeInterval(20)

        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let legacyQueue = try DatabaseQueue(path: databaseURL.path)
        try legacyQueue.write { db in
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
                CREATE TABLE transcript_segments (
                    id BLOB PRIMARY KEY,
                    meetingId BLOB NOT NULL,
                    startTime DATETIME NOT NULL,
                    endTime DATETIME,
                    text TEXT NOT NULL,
                    translatedText TEXT,
                    isConfirmed BOOLEAN NOT NULL DEFAULT 0,
                    speakerLabel TEXT
                )
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE screenshots (
                    id BLOB PRIMARY KEY,
                    meetingId BLOB NOT NULL,
                    capturedAt DATETIME NOT NULL,
                    imageData BLOB NOT NULL,
                    mimeType TEXT NOT NULL
                )
                """
            )
            try db.create(table: "grdb_migrations") { t in
                t.column("identifier", .text).primaryKey()
            }
            for migration in [
                "v3_googleDriveFolderSchema",
                "v4_instructionsSchema",
                "v5_summaryGoogleFileId",
                "v6_transcriptSegmentTranslation",
                "v7_normalizeLegacyMeetingStatus",
            ] {
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [migration])
            }
            try db.execute(
                sql: """
                INSERT INTO meetings (id, vaultId, name, status, duration, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [meetingID, UUID.v7(), "Legacy", MeetingStatus.ready.rawValue, nil as TimeInterval?, meetingStart, meetingStart]
            )
            try db.execute(
                sql: """
                INSERT INTO transcript_segments (id, meetingId, startTime, endTime, text, isConfirmed, speakerLabel)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [segmentID, meetingID, segmentStart, segmentEnd, "Hello world", true, "mic"]
            )
            try db.execute(
                sql: """
                INSERT INTO screenshots (id, meetingId, capturedAt, imageData, mimeType)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [screenshotID, meetingID, segmentStart, Data([0x00]), "image/png"]
            )
        }

        let migrated = try AppDatabaseManager(path: databaseURL.path)
        let result = try migrated.dbQueue.read { db in
            let sessions = try RecordingSessionRecord.filter(Column("meetingId") == meetingID).fetchAll(db)
            let segment = try TranscriptSegmentRecord.fetchOne(db, key: segmentID)
            let screenshot = try MeetingScreenshotRecord.fetchOne(db, key: screenshotID)
            return try (
                sessions,
                #require(segment),
                #require(screenshot)
            )
        }

        let session = try #require(result.0.first)
        #expect(result.0.count == 1)
        #expect(session.startedAt == segmentStart)
        #expect(session.duration == 15)
        #expect(session.offsetSeconds == 0)
        #expect(result.1.sessionId == session.id)
        #expect(result.1.text == "Hello world")
        #expect(result.2.sessionId == session.id)
    }

    @Test
    func repositoryUpdatesProjectGoogleDriveFolder() throws {
        let database = try AppDatabaseManager(path: ":memory:")
        let repository = MeetingRepository(dbQueue: database.dbQueue)
        let vault = VaultRecord(
            id: .v7(),
            path: "/tmp/test-vault",
            name: "Test Vault",
            createdAt: Date(),
            lastOpenedAt: Date()
        )
        try repository.insertVault(vault)

        let project = try repository.fetchOrCreateProject(name: "Project A", vaultId: vault.id)
        try repository.updateProjectGoogleDriveFolder(id: project.id, folderId: "folder-123")

        let fetchedProject = try repository.fetchProject(id: project.id)
        let updatedProject = try #require(fetchedProject)
        #expect(updatedProject.googleDriveFolderId == "folder-123")
    }

    @Test
    func initializesInstructionsTableWithConstraints() throws {
        let database = try AppDatabaseManager(path: ":memory:")

        let columnNames = try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('instructions')")
        }
        let hasCompositeUniqueIndex = try database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM (
                    SELECT il.name
                    FROM pragma_index_list('instructions') AS il
                    JOIN pragma_index_info(il.name) AS ii
                    WHERE il."unique" = 1
                    GROUP BY il.name
                    HAVING group_concat(ii.name, ',') = 'vaultId,name'
                )
                """
            )
        }

        #expect(columnNames.contains("vaultId"))
        #expect(columnNames.contains("name"))
        #expect(columnNames.contains("content"))
        #expect(hasCompositeUniqueIndex == 1)
    }

    @Test
    func existingV3DatabaseMigratesInstructionsTable() throws {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")

        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let legacyQueue = try DatabaseQueue(path: databaseURL.path)
        try legacyQueue.write { db in
            try db.create(table: "vaults") { t in
                t.primaryKey("id", .blob)
                t.column("path", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastOpenedAt", .datetime).notNull()
            }
            try db.create(table: "grdb_migrations") { t in
                t.column("identifier", .text).primaryKey()
            }
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["v3_googleDriveFolderSchema"]
            )
        }

        let migrated = try AppDatabaseManager(path: databaseURL.path)
        let tables = try migrated.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }

        #expect(tables.contains("instructions"))
    }

    @Test
    func existingV3DatabasePreservesExistingDataDuringMigration() throws {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        let legacyVaultID = UUID.v7()
        let createdAt = Date.now

        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let legacyQueue = try DatabaseQueue(path: databaseURL.path)
        try legacyQueue.write { db in
            try db.create(table: "vaults") { t in
                t.primaryKey("id", .blob)
                t.column("path", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastOpenedAt", .datetime).notNull()
            }
            try db.create(table: "grdb_migrations") { t in
                t.column("identifier", .text).primaryKey()
            }
            try db.execute(
                sql: """
                INSERT INTO vaults (id, path, name, createdAt, lastOpenedAt)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [legacyVaultID, "/tmp/legacy-vault", "Legacy Vault", createdAt, createdAt]
            )
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["v3_googleDriveFolderSchema"]
            )
        }

        let migrated = try AppDatabaseManager(path: databaseURL.path)
        let migratedVault = try migrated.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT id, path, name FROM vaults WHERE id = ?",
                arguments: [legacyVaultID]
            )
        }

        #expect(migratedVault != nil)
        #expect(migratedVault?["path"] == "/tmp/legacy-vault")
        #expect(migratedVault?["name"] == "Legacy Vault")
    }

    @Test
    func existingV4DatabaseMigratesSummaryGoogleFileIdColumn() throws {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")

        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let legacyQueue = try DatabaseQueue(path: databaseURL.path)
        try legacyQueue.write { db in
            try db.create(table: "summaries") { t in
                t.primaryKey("meetingId", .blob)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("summary", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "grdb_migrations") { t in
                t.column("identifier", .text).primaryKey()
            }
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?), (?)",
                arguments: ["v3_googleDriveFolderSchema", "v4_instructionsSchema"]
            )
        }

        let migrated = try AppDatabaseManager(path: databaseURL.path)
        let columns = try migrated.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summaries')")
        }

        #expect(columns.contains("googleFileId"))
    }

    @Test
    func existingV5DatabaseMigratesTranscriptTranslatedTextColumnWithoutDataLoss() throws {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        let segmentID = UUID.v7()
        let meetingID = UUID.v7()
        let startTime = Date(timeIntervalSince1970: 1_776_384_000)

        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let legacyQueue = try DatabaseQueue(path: databaseURL.path)
        try legacyQueue.write { db in
            try db.execute(
                sql: """
                CREATE TABLE transcript_segments (
                    id BLOB PRIMARY KEY,
                    meetingId BLOB NOT NULL,
                    startTime DATETIME NOT NULL,
                    endTime DATETIME,
                    text TEXT NOT NULL,
                    isConfirmed BOOLEAN NOT NULL DEFAULT 0,
                    speakerLabel TEXT
                )
                """
            )
            try db.create(table: "grdb_migrations") { t in
                t.column("identifier", .text).primaryKey()
            }
            try db.execute(
                sql: """
                INSERT INTO transcript_segments (id, meetingId, startTime, text, isConfirmed, speakerLabel)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [segmentID, meetingID, startTime, "Hello world", true, "mic"]
            )
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?), (?), (?)",
                arguments: ["v3_googleDriveFolderSchema", "v4_instructionsSchema", "v5_summaryGoogleFileId"]
            )
        }

        let migrated = try AppDatabaseManager(path: databaseURL.path)
        let result = try migrated.dbQueue.read { db in
            try (
                String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('transcript_segments')"),
                Row.fetchOne(db, sql: "SELECT text, translatedText FROM transcript_segments WHERE id = ?", arguments: [segmentID])
            )
        }

        #expect(result.0.contains("translatedText"))
        #expect(result.1?["text"] == "Hello world")
        #expect(result.1?["translatedText"] == nil as String?)
    }

    @Test
    func existingV8DatabaseMigratesSummaryDocumentColumnWithoutDataLoss() throws {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        let meetingID = UUID.v7()
        let screenshotID = UUID.v7()
        let missingScreenshotID = UUID.v7()
        let createdAt = Date(timeIntervalSince1970: 1_783_536_000)

        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let legacyQueue = try DatabaseQueue(path: databaseURL.path)
        try legacyQueue.write { db in
            try db.create(table: "screenshots") { t in
                t.primaryKey("id", .blob)
                t.column("meetingId", .blob).notNull()
                t.column("sessionId", .blob)
                t.column("capturedAt", .datetime).notNull()
                t.column("imageData", .blob).notNull()
                t.column("mimeType", .text).notNull()
            }
            try db.create(table: "summaries") { t in
                t.primaryKey("meetingId", .blob)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("summary", .text).notNull()
                t.column("googleFileId", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.execute(
                sql: """
                INSERT INTO screenshots (id, meetingId, sessionId, capturedAt, imageData, mimeType)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [screenshotID, meetingID, nil as UUID?, createdAt, Data([0x00]), "image/jpeg"]
            )
            try db.execute(
                sql: """
                INSERT INTO summaries (meetingId, title, summary, googleFileId, createdAt)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    meetingID,
                    "Legacy",
                    "## Summary\n\n![[\(screenshotID.uuidString).jpeg|Valid]]\n\n![[\(missingScreenshotID.uuidString).jpeg]]",
                    "google-123",
                    createdAt,
                ]
            )
            try db.create(table: "grdb_migrations") { t in
                t.column("identifier", .text).primaryKey()
            }
            try db.execute(
                sql: """
                INSERT INTO grdb_migrations (identifier)
                VALUES (?), (?), (?), (?), (?), (?)
                """,
                arguments: [
                    "v3_googleDriveFolderSchema",
                    "v4_instructionsSchema",
                    "v5_summaryGoogleFileId",
                    "v6_transcriptSegmentTranslation",
                    "v7_normalizeLegacyMeetingStatus",
                    "v8_recordingSessions",
                ]
            )
        }

        let migrated = try AppDatabaseManager(path: databaseURL.path)
        let result = try migrated.dbQueue.read { db in
            try (
                String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summaries')"),
                Row.fetchOne(db, sql: "SELECT title, summary, document, googleFileId FROM summaries WHERE meetingId = ?", arguments: [meetingID])
            )
        }

        #expect(result.0.contains("document"))
        #expect(result.1?["title"] == "Legacy")
        #expect(result.1?["summary"] == "## Summary\n\n![[\(screenshotID.uuidString).jpeg|Valid]]\n\n![[\(missingScreenshotID.uuidString).jpeg]]")
        let documentJSON = try #require(result.1?["document"] as String?)
        let document = try JSONDecoder().decode(SummaryDocument.self, from: Data(documentJSON.utf8))
        #expect(document.title == "Legacy")
        #expect(document.sections.first?.heading == "Summary")
        #expect(document.sections.first?.blocks == [.image(screenshotId: screenshotID, caption: "Valid")])
        #expect(result.1?["googleFileId"] == "google-123")
    }
}

#elseif canImport(XCTest)
import XCTest

@MainActor
final class AppDatabaseManagerTests: XCTestCase {
    func testInitializesInMemoryDatabaseWithGoogleDriveFolderColumn() throws {
        let database = try AppDatabaseManager(path: ":memory:")

        let columns = try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('projects')")
        }

        XCTAssertTrue(columns.contains("googleDriveFolderId"))
    }

    func testInitializesInMemoryDatabaseWithSummaryGoogleFileIdColumn() throws {
        let database = try AppDatabaseManager(path: ":memory:")

        let columns = try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summaries')")
        }

        XCTAssertTrue(columns.contains("googleFileId"))
    }

    func testInitializesInMemoryDatabaseWithTranscriptTranslatedTextColumn() throws {
        let database = try AppDatabaseManager(path: ":memory:")

        let columns = try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('transcript_segments')")
        }

        XCTAssertTrue(columns.contains("translatedText"))
    }

    func testRepositoryUpdatesProjectGoogleDriveFolder() throws {
        let database = try AppDatabaseManager(path: ":memory:")
        let repository = MeetingRepository(dbQueue: database.dbQueue)
        let vault = VaultRecord(
            id: .v7(),
            path: "/tmp/test-vault",
            name: "Test Vault",
            createdAt: Date(),
            lastOpenedAt: Date()
        )
        try repository.insertVault(vault)

        let project = try repository.fetchOrCreateProject(name: "Project A", vaultId: vault.id)
        try repository.updateProjectGoogleDriveFolder(id: project.id, folderId: "folder-123")

        let updatedProject = try XCTUnwrap(repository.fetchProject(id: project.id))
        XCTAssertEqual(updatedProject.googleDriveFolderId, "folder-123")
    }

    func testInitializesInstructionsTableWithConstraints() throws {
        let database = try AppDatabaseManager(path: ":memory:")

        let columnNames = try database.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('instructions')")
        }
        let hasCompositeUniqueIndex = try database.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM (
                    SELECT il.name
                    FROM pragma_index_list('instructions') AS il
                    JOIN pragma_index_info(il.name) AS ii
                    WHERE il."unique" = 1
                    GROUP BY il.name
                    HAVING group_concat(ii.name, ',') = 'vaultId,name'
                )
                """
            )
        }

        XCTAssertTrue(columnNames.contains("vaultId"))
        XCTAssertTrue(columnNames.contains("name"))
        XCTAssertTrue(columnNames.contains("content"))
        XCTAssertEqual(hasCompositeUniqueIndex, 1)
    }

    func testExistingV3DatabaseMigratesInstructionsTable() throws {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")

        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let legacyQueue = try DatabaseQueue(path: databaseURL.path)
        try legacyQueue.write { db in
            try db.create(table: "vaults") { t in
                t.primaryKey("id", .blob)
                t.column("path", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastOpenedAt", .datetime).notNull()
            }
            try db.create(table: "grdb_migrations") { t in
                t.column("identifier", .text).primaryKey()
            }
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["v3_googleDriveFolderSchema"]
            )
        }

        let migrated = try AppDatabaseManager(path: databaseURL.path)
        let tables = try migrated.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }

        XCTAssertTrue(tables.contains("instructions"))
    }

    func testExistingV3DatabasePreservesExistingDataDuringMigration() throws {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        let legacyVaultID = UUID.v7()
        let createdAt = Date.now

        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let legacyQueue = try DatabaseQueue(path: databaseURL.path)
        try legacyQueue.write { db in
            try db.create(table: "vaults") { t in
                t.primaryKey("id", .blob)
                t.column("path", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastOpenedAt", .datetime).notNull()
            }
            try db.create(table: "grdb_migrations") { t in
                t.column("identifier", .text).primaryKey()
            }
            try db.execute(
                sql: """
                INSERT INTO vaults (id, path, name, createdAt, lastOpenedAt)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [legacyVaultID, "/tmp/legacy-vault", "Legacy Vault", createdAt, createdAt]
            )
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["v3_googleDriveFolderSchema"]
            )
        }

        let migrated = try AppDatabaseManager(path: databaseURL.path)
        let migratedVault = try migrated.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT id, path, name FROM vaults WHERE id = ?",
                arguments: [legacyVaultID]
            )
        }

        XCTAssertNotNil(migratedVault)
        XCTAssertEqual(migratedVault?["path"], "/tmp/legacy-vault")
        XCTAssertEqual(migratedVault?["name"], "Legacy Vault")
    }

    func testExistingV4DatabaseMigratesSummaryGoogleFileIdColumn() throws {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")

        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let legacyQueue = try DatabaseQueue(path: databaseURL.path)
        try legacyQueue.write { db in
            try db.create(table: "summaries") { t in
                t.primaryKey("meetingId", .blob)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("summary", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "grdb_migrations") { t in
                t.column("identifier", .text).primaryKey()
            }
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?), (?)",
                arguments: ["v3_googleDriveFolderSchema", "v4_instructionsSchema"]
            )
        }

        let migrated = try AppDatabaseManager(path: databaseURL.path)
        let columns = try migrated.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summaries')")
        }

        XCTAssertTrue(columns.contains("googleFileId"))
    }

    func testExistingV5DatabaseMigratesTranscriptTranslatedTextColumnWithoutDataLoss() throws {
        let databaseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        let segmentID = UUID.v7()
        let meetingID = UUID.v7()
        let startTime = Date(timeIntervalSince1970: 1_776_384_000)

        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let legacyQueue = try DatabaseQueue(path: databaseURL.path)
        try legacyQueue.write { db in
            try db.execute(
                sql: """
                CREATE TABLE transcript_segments (
                    id BLOB PRIMARY KEY,
                    meetingId BLOB NOT NULL,
                    startTime DATETIME NOT NULL,
                    endTime DATETIME,
                    text TEXT NOT NULL,
                    isConfirmed BOOLEAN NOT NULL DEFAULT 0,
                    speakerLabel TEXT
                )
                """
            )
            try db.create(table: "grdb_migrations") { t in
                t.column("identifier", .text).primaryKey()
            }
            try db.execute(
                sql: """
                INSERT INTO transcript_segments (id, meetingId, startTime, text, isConfirmed, speakerLabel)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [segmentID, meetingID, startTime, "Hello world", true, "mic"]
            )
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?), (?), (?)",
                arguments: ["v3_googleDriveFolderSchema", "v4_instructionsSchema", "v5_summaryGoogleFileId"]
            )
        }

        let migrated = try AppDatabaseManager(path: databaseURL.path)
        let result = try migrated.dbQueue.read { db in
            try (
                String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('transcript_segments')"),
                Row.fetchOne(db, sql: "SELECT text, translatedText FROM transcript_segments WHERE id = ?", arguments: [segmentID])
            )
        }

        XCTAssertTrue(result.0.contains("translatedText"))
        XCTAssertEqual(result.1?["text"], "Hello world")
        XCTAssertNil(result.1?["translatedText"] as String?)
    }
}
#endif
