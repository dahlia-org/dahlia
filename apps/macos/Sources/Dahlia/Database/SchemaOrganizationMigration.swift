import GRDB

enum SchemaOrganizationMigration {
    static func migrate(in db: Database) throws {
        if try db.tableExists("search_index_jobs") {
            // Older migrations can leave temporarily unresolved triggers; rename only this table's references.
            let triggers = try Row.fetchAll(db, sql: """
            SELECT name, sql FROM sqlite_master
            WHERE type = 'trigger' AND sql LIKE '%search_index_jobs%'
            """)
            for trigger in triggers {
                let name: String = trigger["name"]
                try db.execute(sql: "DROP TRIGGER \(name.quotedDatabaseIdentifier)")
            }
            let legacyAlter = try Bool.fetchOne(db, sql: "PRAGMA legacy_alter_table") ?? false
            try db.execute(sql: "PRAGMA legacy_alter_table = ON")
            defer { try? db.execute(sql: "PRAGMA legacy_alter_table = \(legacyAlter ? "ON" : "OFF")") }
            try db.execute(sql: "ALTER TABLE search_index_jobs RENAME TO jobs_search_index")
            for trigger in triggers {
                let sql: String = trigger["sql"]
                try db.execute(sql: sql.replacingOccurrences(of: "search_index_jobs", with: "jobs_search_index"))
            }
        }
        if try !db.columns(in: "projects").contains(where: { $0.name == "legacyAppearanceMigrated" }) {
            try db.alter(table: "projects") { $0.add(column: "legacyAppearanceMigrated", .boolean).notNull().defaults(to: false) }
        }
        for table in ["projects", "vaults"] where try db.tableExists(table) {
            let columns = try db.columns(in: table).map(\.name)
            for column in ["icon", "color"] where !columns.contains(column) {
                try db.alter(table: table) { $0.add(column: column, .text) }
            }
        }
    }
}
