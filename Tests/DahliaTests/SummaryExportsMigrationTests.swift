import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SummaryExportsMigrationTests {
        @Test
        func initializesDatabaseWithCanonicalSummarySchema() throws {
            let database = try AppDatabaseManager(path: ":memory:")

            let result = try database.dbQueue.read { db in
                try (
                    db.columns(in: "summaries"),
                    String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summary_exports')")
                )
            }

            #expect(result.0.map(\.name) == ["meetingId", "title", "document", "createdAt"])
            #expect(result.0.first(where: { $0.name == "document" })?.isNotNull == true)
            #expect(result.1 == ["meetingId", "type", "url", "createdAt", "updatedAt"])
        }

        @Test
        func removesLegacyColumnsAndKeepsExportsForValidDocuments() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: UUID.v7().uuidString)
                .appendingPathExtension("sqlite")
            let validMeetingId = UUID.v7()
            let legacyGoogleMeetingId = UUID.v7()
            let nilDocumentMeetingId = UUID.v7()
            let invalidDocumentMeetingId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            defer { try? FileManager.default.removeItem(at: databaseURL) }

            let legacyQueue = try DatabaseQueue(path: databaseURL.path)
            try createV20SummaryDatabase(
                in: legacyQueue,
                validMeetingId: validMeetingId,
                legacyGoogleMeetingId: legacyGoogleMeetingId,
                nilDocumentMeetingId: nilDocumentMeetingId,
                invalidDocumentMeetingId: invalidDocumentMeetingId,
                createdAt: createdAt
            )

            let migrated = try AppDatabaseManager(path: databaseURL.path)
            let result = try migrated.dbQueue.read { db in
                try (
                    db.columns(in: "summaries"),
                    SummaryRecord.fetchOne(db, key: validMeetingId),
                    SummaryRecord.fetchOne(db, key: legacyGoogleMeetingId),
                    SummaryExportRecord
                        .filter(Column("meetingId") == validMeetingId)
                        .order(Column("type"))
                        .fetchAll(db),
                    SummaryExportRecord
                        .filter(Column("meetingId") == legacyGoogleMeetingId)
                        .fetchAll(db),
                    SummaryRecord.fetchCount(db),
                    SummaryExportRecord.fetchCount(db)
                )
            }

            #expect(result.0.map(\.name) == ["meetingId", "title", "document", "createdAt"])
            #expect(result.0.first(where: { $0.name == "document" })?.isNotNull == true)
            #expect(result.1?.title == "Stored SQL title")
            #expect(result.1?.createdAt == createdAt)
            #expect(try result.1?.loadDocument().title == "Canonical")
            #expect(result.2?.meetingId == legacyGoogleMeetingId)
            #expect(result.3 == [
                SummaryExportRecord(
                    meetingId: validMeetingId,
                    type: .googleDocs,
                    url: "https://example.com/canonical-google-doc",
                    createdAt: createdAt,
                    updatedAt: createdAt
                ),
                SummaryExportRecord(
                    meetingId: validMeetingId,
                    type: .vault,
                    url: "vault:///Project/Summary.md",
                    createdAt: createdAt,
                    updatedAt: createdAt
                ),
            ])
            #expect(result.4.map(\.url) == ["https://docs.google.com/document/d/legacy-google-only/edit"])
            #expect(result.5 == 2)
            #expect(result.6 == 3)

            try migrated.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [validMeetingId])
            }
            let deletedCounts = try migrated.dbQueue.read { db in
                try (
                    SummaryRecord.filter(Column("meetingId") == validMeetingId).fetchCount(db),
                    SummaryExportRecord.filter(Column("meetingId") == validMeetingId).fetchCount(db)
                )
            }
            #expect(deletedCounts.0 == 0)
            #expect(deletedCounts.1 == 0)
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

        private func createV20SummaryDatabase(
            in dbQueue: DatabaseQueue,
            validMeetingId: UUID,
            legacyGoogleMeetingId: UUID,
            nilDocumentMeetingId: UUID,
            invalidDocumentMeetingId: UUID,
            createdAt: Date
        ) throws {
            let validDocument = try SummaryDocument(
                title: "Canonical",
                sections: [SummarySection(id: .v7(), heading: "Summary", blocks: [.paragraph("Body")])]
            ).databaseJSONString()
            try dbQueue.write { db in
                try db.create(table: "meetings") { table in
                    table.primaryKey("id", .blob)
                }
                try db.execute(
                    sql: "INSERT INTO meetings (id) VALUES (?), (?), (?), (?)",
                    arguments: [validMeetingId, legacyGoogleMeetingId, nilDocumentMeetingId, invalidDocumentMeetingId]
                )
                try db.create(table: "summaries") { table in
                    table.primaryKey("meetingId", .blob)
                        .references("meetings", onDelete: .cascade)
                    table.column("title", .text).notNull().defaults(to: "")
                    table.column("summary", .text).notNull()
                    table.column("document", .text)
                    table.column("vaultRelativePath", .text)
                    table.column("googleFileId", .text)
                    table.column("createdAt", .datetime).notNull()
                }
                try db.create(table: "summary_exports") { table in
                    table.column("meetingId", .blob).notNull()
                        .references("summaries", column: "meetingId", onDelete: .cascade)
                    table.column("type", .text).notNull()
                    table.column("url", .text).notNull()
                    table.column("createdAt", .datetime).notNull()
                    table.column("updatedAt", .datetime).notNull()
                    table.primaryKey(["meetingId", "type"])
                }
                try db.create(table: "grdb_migrations") { table in
                    table.column("identifier", .text).primaryKey()
                }
                for migration in Self.v20MigrationIdentifiers {
                    try db.execute(
                        sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                        arguments: [migration]
                    )
                }
                try db.execute(
                    sql: """
                    INSERT INTO summaries (
                        meetingId, title, summary, document, vaultRelativePath, googleFileId, createdAt
                    ) VALUES
                        (?, 'Stored SQL title', 'Legacy body', ?, 'Project/Summary.md', 'legacy-google', ?),
                        (?, 'Legacy Google', 'Legacy body', ?, NULL, 'legacy-google-only', ?),
                        (?, 'No document', 'Ignored', NULL, 'Ignored/Nil.md', NULL, ?),
                        (?, 'Invalid document', 'Ignored', 'not-json', 'Ignored/Invalid.md', NULL, ?)
                    """,
                    arguments: [
                        validMeetingId, validDocument, createdAt,
                        legacyGoogleMeetingId, validDocument, createdAt,
                        nilDocumentMeetingId, createdAt,
                        invalidDocumentMeetingId, createdAt,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO summary_exports (meetingId, type, url, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        validMeetingId, SummaryExportType.googleDocs, "https://example.com/canonical-google-doc", createdAt, createdAt,
                        invalidDocumentMeetingId, SummaryExportType.googleDocs, "https://example.com/ignored", createdAt, createdAt,
                    ]
                )
            }
        }

        private static let v20MigrationIdentifiers = [
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
            "v20_meetingDescription",
        ]
    }
#endif
