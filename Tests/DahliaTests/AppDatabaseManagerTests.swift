import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    // Migration coverage is intentionally kept in one suite so schema versions remain easy to audit together.
    // swiftlint:disable:next type_body_length
    struct AppDatabaseManagerTests {
        @Test
        func databaseFileUsesPrivatePermissions() throws {
            let databaseURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-database-permissions-\(UUID.v7().uuidString)")
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }

            _ = try AppDatabaseManager(path: databaseURL.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue == 0o600)
        }

        @Test
        func initializesInMemoryDatabaseWithGoogleDriveFolderColumn() throws {
            let database = try AppDatabaseManager(path: ":memory:")

            let columns = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('projects')")
            }

            #expect(columns.contains("googleDriveFolderId"))
            #expect(columns.contains("description"))
            #expect(columns.contains("legacyContextMigrated"))
        }

        @Test
        func existingProjectsGainEmptyDescriptionWithoutDataLoss() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: UUID().uuidString)
                .appendingPathExtension("sqlite")
            let projectId = UUID.v7()
            let vaultId = UUID.v7()
            defer { try? FileManager.default.removeItem(at: databaseURL) }

            let legacyQueue = try DatabaseQueue(path: databaseURL.path)
            try legacyQueue.write { db in
                try db.execute(
                    sql: """
                    CREATE TABLE projects (
                        id BLOB PRIMARY KEY,
                        vaultId BLOB NOT NULL,
                        name TEXT NOT NULL,
                        createdAt DATETIME NOT NULL,
                        googleDriveFolderId TEXT,
                        missingOnDisk BOOLEAN NOT NULL DEFAULT 0,
                        UNIQUE(vaultId, name)
                    )
                    """
                )
                try db.create(table: "grdb_migrations") { table in
                    table.column("identifier", .text).primaryKey()
                }
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
                ] {
                    try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [migration])
                }
                try db.execute(
                    sql: """
                    INSERT INTO projects (id, vaultId, name, createdAt, googleDriveFolderId, missingOnDisk)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [projectId, vaultId, "Existing Project", Date.now, "folder-123", false]
                )
            }

            let migrated = try AppDatabaseManager(path: databaseURL.path)
            let row = try migrated.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM projects WHERE id = ?",
                    arguments: [projectId]
                )
            }

            let existingRow = try #require(row)
            let existingProject = try ProjectRecord(row: existingRow)
            #expect(existingProject.name == "Existing Project")
            #expect(existingProject.description.isEmpty)
            #expect(existingRow["googleDriveFolderId"] == "folder-123" as String?)
        }

        @Test
        func initializesInMemoryDatabaseWithoutLegacySummaryColumns() throws {
            let database = try AppDatabaseManager(path: ":memory:")

            let columns = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summaries')")
            }

            #expect(columns == ["meetingId", "title", "document", "createdAt"])
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
        func initializesBatchTranscriptionSchema() throws {
            let database = try AppDatabaseManager(path: ":memory:")

            let result = try database.dbQueue.read { db in
                try (
                    String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('recording_sessions')"),
                    String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('recording_audio_files')"),
                    db.tableExists("recording_audio_ranges")
                )
            }

            #expect(result.0.contains("transcriptionMode"))
            #expect(result.0.contains("retainAudioAfterBatch"))
            #expect(result.0.contains("batchCompletedAt"))
            #expect(result.0.contains("batchLastError"))
            #expect(result.0.contains("batchLastAttemptAt"))
            #expect(result.0.contains("batchAttemptCount"))
            #expect(result.0.contains("batchDiscardedAt"))
            #expect(result.1.contains("storageLocation"))
            #expect(result.2)
        }

        @Test
        func initializesSegmentedRecordingAudioSchema() throws {
            let database = try AppDatabaseManager(path: ":memory:")

            let result = try database.dbQueue.read { db in
                try (
                    db.tableExists("recording_audio_segments"),
                    db.tableExists("recording_audio_segment_ranges"),
                    db.tableExists("recording_audio_source_progress"),
                    db.tableExists("recording_audio_reconciliation_issues"),
                    String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('recording_sessions')")
                )
            }

            #expect(result.0)
            #expect(result.1)
            #expect(result.2)
            #expect(result.3)
            #expect(result.4.contains("audioRetentionPolicy"))
            #expect(result.4.contains("retentionExpiresAt"))
            #expect(result.4.contains("batchFailureKind"))
        }

        @Test
        func existingV17AudioRowsSurviveSegmentedAudioMigration() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: UUID.v7().uuidString)
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let sessionId = UUID.v7()
            let fileId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_776_384_000)
            let queue = try DatabaseQueue(path: databaseURL.path)
            try queue.write { db in
                try db.create(table: "recording_sessions") { table in
                    table.primaryKey("id", .blob)
                }
                try db.create(table: "recording_audio_files") { table in
                    table.primaryKey("id", .blob)
                    table.column("recordingSessionId", .blob).notNull()
                    table.column("source", .text).notNull()
                    table.column("storageLocation", .text).notNull()
                    table.column("relativePath", .text).notNull()
                    table.column("sampleRate", .double).notNull()
                    table.column("channelCount", .integer).notNull()
                    table.column("finalizedAt", .datetime)
                    table.column("totalFrameCount", .integer)
                    table.column("createdAt", .datetime).notNull()
                    table.column("updatedAt", .datetime).notNull()
                    table.uniqueKey(["recordingSessionId", "source"])
                }
                try db.create(table: "grdb_migrations") { table in
                    table.column("identifier", .text).primaryKey()
                }
                let migrations = [
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
                    "v15_calendarEventIdentity",
                    "v16_calendarEventURL",
                    "v17_calendarEventIntegrity",
                ]
                for migration in migrations {
                    try db.execute(
                        sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                        arguments: [migration]
                    )
                }
                try db.execute(sql: "INSERT INTO recording_sessions (id) VALUES (?)", arguments: [sessionId])
                try db.execute(
                    sql: """
                    INSERT INTO recording_audio_files (
                        id, recordingSessionId, source, storageLocation, relativePath,
                        sampleRate, channelCount, finalizedAt, totalFrameCount, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        fileId,
                        sessionId,
                        RecordingAudioSource.microphone.rawValue,
                        RecordingAudioStorageLocation.managed.rawValue,
                        "legacy/microphone.caf",
                        16000,
                        1,
                        createdAt,
                        320,
                        createdAt,
                        createdAt,
                    ]
                )
            }

            let migrated = try AppDatabaseManager(path: databaseURL.path)
            let result = try migrated.dbQueue.read { db in
                try (
                    Row.fetchOne(db, sql: "SELECT * FROM recording_audio_files WHERE id = ?", arguments: [fileId]),
                    db.tableExists("recording_audio_segments")
                )
            }
            let row = try #require(result.0)
            #expect(row["relativePath"] == "legacy/microphone.caf")
            #expect(row["totalFrameCount"] == 320 as Int64?)
            #expect(result.1)
        }

        @Test
        // This fixture spells out the complete v7 schema and migrated data assertions.
        // swiftlint:disable:next function_body_length
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
            #expect(session.transcriptionMode == .realtime)
            #expect(result.1.sessionId == session.id)
            #expect(result.1.text == "Hello world")
            #expect(result.2.sessionId == session.id)
        }

        @Test
        func repositoryUpdatesProjectDescription() throws {
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
            try repository.updateProjectDescription(id: project.id, description: "Customer rollout")

            let fetchedProject = try repository.fetchProject(id: project.id)
            let updatedProject = try #require(fetchedProject)
            #expect(updatedProject.description == "Customer rollout")
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
        func existingV4DatabaseRemovesLegacySummaryColumns() throws {
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

            #expect(columns == ["meetingId", "title", "document", "createdAt"])
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
        func existingV8DatabaseDropsSummaryWithoutDocument() throws {
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
                    SummaryRecord.fetchOne(db, key: meetingID),
                    SummaryExportRecord.fetchCount(db)
                )
            }

            #expect(result.0 == ["meetingId", "title", "document", "createdAt"])
            #expect(result.1 == nil)
            #expect(result.2 == 0)
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

        func testInitializesInMemoryDatabaseWithoutLegacySummaryColumns() throws {
            let database = try AppDatabaseManager(path: ":memory:")

            let columns = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summaries')")
            }

            XCTAssertEqual(columns, ["meetingId", "title", "document", "createdAt"])
        }

        func testInitializesInMemoryDatabaseWithTranscriptTranslatedTextColumn() throws {
            let database = try AppDatabaseManager(path: ":memory:")

            let columns = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('transcript_segments')")
            }

            XCTAssertTrue(columns.contains("translatedText"))
        }

        func testRepositoryUpdatesProjectDescription() throws {
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
            try repository.updateProjectDescription(id: project.id, description: "Customer rollout")

            let updatedProject = try XCTUnwrap(repository.fetchProject(id: project.id))
            XCTAssertEqual(updatedProject.description, "Customer rollout")
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

        func testExistingV4DatabaseRemovesLegacySummaryColumns() throws {
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

            XCTAssertEqual(columns, ["meetingId", "title", "document", "createdAt"])
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
