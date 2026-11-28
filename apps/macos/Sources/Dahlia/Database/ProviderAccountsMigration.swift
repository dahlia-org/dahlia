import GRDB

/// `accounts` becomes `provider_accounts`: the external connections the app holds credentials for, which features use
/// by capability. The app itself has one account, so the table no longer lists accounts to switch between. A display
/// name distinguishes connections; settingsJSON holds the capabilities’ non-secret account settings.
enum ProviderAccountsMigration {
    static func migrate(in db: Database) throws {
        // Tests of early schemas run every migration on a database with only some tables.
        guard try db.tableExists("accounts") else { return }
        let legacyAlter = try Bool.fetchOne(db, sql: "PRAGMA legacy_alter_table") ?? false
        // OFF makes SQLite rewrite the foreign keys that name the renamed table. It also checks every trigger, so they
        // are set aside and recreated unchanged, as `v57_accountsTable` does; a failure rolls back.
        try db.execute(sql: "PRAGMA legacy_alter_table = OFF")
        defer { try? db.execute(sql: "PRAGMA legacy_alter_table = \(legacyAlter ? "ON" : "OFF")") }
        let triggers = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'trigger'")
        for trigger in triggers {
            let name: String = trigger["name"]
            try db.execute(sql: "DROP TRIGGER \(name.quotedDatabaseIdentifier)")
        }
        try db.execute(sql: """
        ALTER TABLE accounts RENAME TO provider_accounts;
        ALTER TABLE provider_accounts ADD COLUMN name TEXT;
        """)
        try db.alter(table: "provider_accounts") { table in
            table.add(column: "settingsJSON", .text).notNull().defaults(to: "{}")
                .check(sql: "json_valid(settingsJSON) AND json_type(settingsJSON) = 'object'")
        }
        for trigger in triggers {
            if let sql: String = trigger["sql"] {
                try db.execute(sql: sql)
            }
        }
    }
}
