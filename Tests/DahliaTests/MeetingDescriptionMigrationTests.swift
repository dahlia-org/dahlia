import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingDescriptionMigrationTests {
        @Test
        func v20AddsEmptyMeetingDescriptionWithoutChangingExistingName() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: UUID().uuidString)
                .appendingPathExtension("sqlite")
            let meetingID = UUID.v7()
            let vaultID = UUID.v7()
            defer { try? FileManager.default.removeItem(at: databaseURL) }

            let legacyQueue = try DatabaseQueue(path: databaseURL.path)
            try legacyQueue.write { db in
                try db.execute(sql: """
                CREATE TABLE meetings (
                    id BLOB PRIMARY KEY,
                    vaultId BLOB NOT NULL,
                    projectId BLOB,
                    name TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'TRANSCRIPT_NOT_FOUND',
                    duration DOUBLE,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
                """)
                try db.create(table: "grdb_migrations") { table in
                    table.column("identifier", .text).primaryKey()
                }
                for migration in Self.preV20MigrationIdentifiers {
                    try db.execute(
                        sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                        arguments: [migration]
                    )
                }
                try db.execute(
                    sql: """
                    INSERT INTO meetings (id, vaultId, name, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [meetingID, vaultID, "Existing name", Date.now, Date.now]
                )
            }

            let migrated = try AppDatabaseManager(path: databaseURL.path)
            let row = try migrated.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT name, description FROM meetings WHERE id = ?",
                    arguments: [meetingID]
                )
            }

            #expect(row?["name"] == "Existing name" as String?)
            #expect((row?["description"] as String?)?.isEmpty == true)
        }

        private static let preV20MigrationIdentifiers = [
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
            "v18_segmentedRecordingAudio",
            "v19_summaryExports",
        ]
    }
#endif
