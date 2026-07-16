import Foundation
import GRDB

enum LegacySummaryColumnsMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists("summaries") else { return }
        let columns = try db.columns(in: "summaries").map(\.name)
        guard columns.contains("document") else { return }

        try SummaryExportsMigration.migrate(in: db)
        try createReplacementTables(in: db)
        try copyValidSummaries(in: db)
        try db.execute(
            sql: """
            INSERT INTO summary_exports_v21 (meetingId, type, url, createdAt, updatedAt)
            SELECT exports.meetingId, exports.type, exports.url, exports.createdAt, exports.updatedAt
            FROM summary_exports AS exports
            JOIN summaries_v21 AS summaries ON summaries.meetingId = exports.meetingId
            """
        )

        try db.drop(table: "summary_exports")
        try db.drop(table: "summaries")
        try db.rename(table: "summaries_v21", to: "summaries")
        try createSummaryExportsTable(in: db)
        try db.execute(
            sql: """
            INSERT INTO summary_exports (meetingId, type, url, createdAt, updatedAt)
            SELECT meetingId, type, url, createdAt, updatedAt
            FROM summary_exports_v21
            """
        )
        try db.drop(table: "summary_exports_v21")
        try db.create(
            index: "summary_exports_on_type",
            on: "summary_exports",
            columns: ["type"],
            ifNotExists: true
        )
    }

    private static func createReplacementTables(in db: Database) throws {
        let hasMeetingsTable = try db.tableExists("meetings")
        try db.create(table: "summaries_v21") { table in
            let meetingId = table.primaryKey("meetingId", .blob)
            if hasMeetingsTable {
                meetingId.references("meetings", onDelete: .cascade)
            }
            table.column("title", .text).notNull().defaults(to: "")
            table.column("document", .text).notNull()
            table.column("createdAt", .datetime).notNull()
        }
        try db.create(table: "summary_exports_v21") { table in
            table.column("meetingId", .blob).notNull()
            table.column("type", .text).notNull()
            table.column("url", .text).notNull()
            table.column("createdAt", .datetime).notNull()
            table.column("updatedAt", .datetime).notNull()
            table.primaryKey(["meetingId", "type"])
        }
    }

    private static func createSummaryExportsTable(in db: Database) throws {
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

    private static func copyValidSummaries(in db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT meetingId, title, document, createdAt FROM summaries"
        )
        for row in rows {
            guard let document: String = row["document"],
                  (try? JSONDecoder().decode(SummaryDocument.self, from: Data(document.utf8))) != nil
            else { continue }
            let meetingId: UUID = row["meetingId"]
            let title: String = row["title"]
            let createdAt: Date = row["createdAt"]
            try db.execute(
                sql: """
                INSERT INTO summaries_v21 (meetingId, title, document, createdAt)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [meetingId, title, document, createdAt]
            )
        }
    }
}
