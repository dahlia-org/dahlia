import Foundation
import GRDB

enum SummaryExportsMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists("summaries") else { return }

        try createTableIfNeeded(in: db)
        try backfillLegacyVaultExports(in: db)
        try backfillLegacyGoogleDocsExports(in: db)
    }

    private static func createTableIfNeeded(in db: Database) throws {
        if try !db.tableExists("summary_exports") {
            try db.create(table: "summary_exports") { table in
                table.column("meetingId", .blob).notNull()
                    .references("summaries", column: "meetingId", onDelete: .cascade)
                table.column("type", .text).notNull()
                table.column("url", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.primaryKey(["meetingId", "type"])
            }
        }
        try db.create(
            index: "summary_exports_on_type",
            on: "summary_exports",
            columns: ["type"],
            ifNotExists: true
        )
    }

    private static func backfillLegacyVaultExports(in db: Database) throws {
        guard try db.columns(in: "summaries").contains(where: { $0.name == "vaultRelativePath" }) else { return }
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT meetingId, vaultRelativePath, createdAt
            FROM summaries
            WHERE vaultRelativePath IS NOT NULL AND TRIM(vaultRelativePath) <> ''
            """
        )
        for row in rows {
            let relativePath: String = row["vaultRelativePath"]
            guard let url = SummaryExportRecord.vaultURL(relativePath: relativePath) else { continue }
            try insertExport(type: .vault, url: url, from: row, in: db)
        }
    }

    private static func backfillLegacyGoogleDocsExports(in db: Database) throws {
        guard try db.columns(in: "summaries").contains(where: { $0.name == "googleFileId" }) else { return }
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT meetingId, googleFileId, createdAt
            FROM summaries
            WHERE googleFileId IS NOT NULL AND TRIM(googleFileId) <> ''
            """
        )
        for row in rows {
            let fileId: String = row["googleFileId"]
            guard let url = SummaryExportRecord.googleDocsURL(fileId: fileId) else { continue }
            try insertExport(type: .googleDocs, url: url, from: row, in: db)
        }
    }

    private static func insertExport(
        type: SummaryExportType,
        url: String,
        from row: Row,
        in db: Database
    ) throws {
        let meetingId: UUID = row["meetingId"]
        let createdAt: Date = row["createdAt"]
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO summary_exports (meetingId, type, url, createdAt, updatedAt)
            VALUES (?, ?, ?, ?, ?)
            """,
            arguments: [meetingId, type, url, createdAt, createdAt]
        )
    }
}
