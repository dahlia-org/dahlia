import GRDB

/// Completes the unpublished v42 rebuild. SQLite rewrites dependent foreign keys and views.
enum WorkspaceNamingMigration {
    static func migrate(in db: Database) throws {
        let legacyAlter = try Bool.fetchOne(db, sql: "PRAGMA legacy_alter_table") ?? false
        try db.execute(sql: "PRAGMA legacy_alter_table = OFF")
        defer { try? db.execute(sql: "PRAGMA legacy_alter_table = \(legacyAlter ? "ON" : "OFF")") }
        // Recreate triggers after renaming: their identifiers and entity literals also changed.
        let triggers = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'trigger'")
        for trigger in triggers {
            let name: String = trigger["name"]
            try db.execute(sql: "DROP TRIGGER \(name.quotedDatabaseIdentifier)")
        }
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        for oldName in tables {
            let name = oldName.replacingOccurrences(of: "vault", with: "workspace")
            if name != oldName {
                try db.execute(sql: "ALTER TABLE \(oldName.quotedDatabaseIdentifier) RENAME TO \(name.quotedDatabaseIdentifier)")
            }
            for column in try db.columns(in: name) {
                let renamed = rename(column.name)
                if renamed != column.name {
                    try db
                        .execute(
                            sql: "ALTER TABLE \(name.quotedDatabaseIdentifier) RENAME COLUMN \(column.name.quotedDatabaseIdentifier) TO \(renamed.quotedDatabaseIdentifier)"
                        )
                }
            }
        }
        let indexes = try Row.fetchAll(
            db,
            sql: "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL AND name LIKE '%vault%'"
        )
        for index in indexes {
            let name: String = index["name"]
            let sql: String = index["sql"]
            try db.execute(sql: "DROP INDEX \(name.quotedDatabaseIdentifier)")
            try db.execute(sql: rename(sql))
        }
        if try db.tableExists("sync_entity_state") {
            try db.execute(sql: "UPDATE sync_entity_state SET entity = 'workspace' WHERE entity = 'vault'")
        }
        if try db.tableExists("jobs_search_index") {
            try db.execute(sql: "UPDATE jobs_search_index SET targetKind = 'workspaceCleanup' WHERE targetKind = 'vaultCleanup'")
        }
        for table in ["workspaces", "projects"] where try db.tableExists(table) {
            if try db.columns(in: table).contains(where: { $0.name == "icon" }) {
                try db.execute(sql: "UPDATE \(table) SET icon = 'workspace' WHERE icon = 'vault'")
            }
        }
        for trigger in triggers {
            let sql: String = trigger["sql"]
            try db.execute(sql: rename(sql))
        }
        guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
            throw DatabaseError(message: "Workspace migration left invalid references")
        }
    }

    private static func rename(_ value: String) -> String {
        value.replacingOccurrences(of: "sourceVaultId", with: "source_workspace_id")
            .replacingOccurrences(of: "destinationVaultId", with: "destination_workspace_id")
            .replacingOccurrences(of: "originalVaultPath", with: "original_workspace_path")
            .replacingOccurrences(of: "vaultId", with: "workspace_id")
            .replacingOccurrences(of: "Vault", with: "Workspace")
            .replacingOccurrences(of: "vault", with: "workspace")
    }
}
