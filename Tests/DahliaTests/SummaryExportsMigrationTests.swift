import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SummaryExportsMigrationTests {
        @Test
        func initializesDatabaseWithSummaryExportsTable() throws {
            let database = try AppDatabaseManager(path: ":memory:")

            let columns = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summary_exports')")
            }

            #expect(columns == ["meetingId", "type", "url", "createdAt", "updatedAt"])
        }

        @Test
        func migratesLegacyExportLocationsWithoutRemovingLegacyValues() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: UUID.v7().uuidString)
                .appendingPathExtension("sqlite")
            let meetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            defer { try? FileManager.default.removeItem(at: databaseURL) }

            let legacyQueue = try DatabaseQueue(path: databaseURL.path)
            try createV18SummaryDatabase(
                in: legacyQueue,
                meetingId: meetingId,
                createdAt: createdAt
            )

            let migrated = try AppDatabaseManager(path: databaseURL.path)
            let result = try migrated.dbQueue.read { db in
                let exports = try SummaryExportRecord
                    .filter(Column("meetingId") == meetingId)
                    .order(Column("type"))
                    .fetchAll(db)
                let legacy = try Row.fetchOne(
                    db,
                    sql: "SELECT vaultRelativePath, googleFileId FROM summaries WHERE meetingId = ?",
                    arguments: [meetingId]
                )
                return try (exports, #require(legacy))
            }

            #expect(result.0 == [
                SummaryExportRecord(
                    meetingId: meetingId,
                    type: .googleDocs,
                    url: "https://docs.google.com/document/d/google-123/edit",
                    createdAt: createdAt,
                    updatedAt: createdAt
                ),
                SummaryExportRecord(
                    meetingId: meetingId,
                    type: .vault,
                    url: "vault:///Project/Summary.md",
                    createdAt: createdAt,
                    updatedAt: createdAt
                ),
            ])
            #expect(result.1["vaultRelativePath"] == "Project/Summary.md" as String?)
            #expect(result.1["googleFileId"] == "google-123" as String?)
        }

        @Test
        func vaultURLRoundTripsRelativePathsWithReservedCharacters() throws {
            let url = try #require(SummaryExportRecord.vaultURL(relativePath: "Project/My Summary #1.md"))
            let record = SummaryExportRecord(
                meetingId: .v7(),
                type: .vault,
                url: url,
                createdAt: .now,
                updatedAt: .now
            )

            #expect(url == "vault:///Project/My%20Summary%20%231.md")
            #expect(record.vaultRelativePath == "Project/My Summary #1.md")
        }

        private func createV18SummaryDatabase(
            in dbQueue: DatabaseQueue,
            meetingId: UUID,
            createdAt: Date
        ) throws {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    CREATE TABLE summaries (
                        meetingId BLOB PRIMARY KEY,
                        title TEXT NOT NULL DEFAULT '',
                        summary TEXT NOT NULL,
                        document TEXT,
                        vaultRelativePath TEXT,
                        googleFileId TEXT,
                        createdAt DATETIME NOT NULL
                    )
                    """
                )
                try db.create(table: "grdb_migrations") { table in
                    table.column("identifier", .text).primaryKey()
                }
                for migration in Self.v18MigrationIdentifiers {
                    try db.execute(
                        sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                        arguments: [migration]
                    )
                }
                try db.execute(
                    sql: """
                    INSERT INTO summaries (
                        meetingId, title, summary, document, vaultRelativePath, googleFileId, createdAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        meetingId,
                        "Legacy",
                        "Body",
                        nil,
                        "Project/Summary.md",
                        "google-123",
                        createdAt,
                    ]
                )
            }
        }

        private static let v18MigrationIdentifiers = [
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
        ]
    }
#endif
