import GRDB

/// Only unshipped registrations are merged. GRDB preserves and recognizes existing development DBs.
enum DocumentsAndSyncMigration {
    static let legacyIdentifiers: Set = [
        "v47_documents", "v48_independentDocuments", "v49_workspaceImportDestinations",
        "v50_syncPriority", "v51_scopedSyncReconciliation", "v52_documentsAndSync", "v53_sharedBackgroundJobs",
    ]

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v53_documentsSyncAndBackgroundJobs", merging: legacyIdentifiers) { db, applied in
            try migrateDocumentsAndSync(in: db, applied: applied)
            if !applied.contains("v53_sharedBackgroundJobs") { try BackgroundJobsMigration.migrate(in: db) }
        }
    }

    static func migrateDocumentsAndSync(in db: Database, applied: Set<String>) throws {
        if !applied.contains("v52_documentsAndSync") {
            if !applied.contains("v48_independentDocuments") {
                if applied.contains("v47_documents") {
                    try IndependentDocumentsMigration.migrate(in: db)
                } else {
                    try DocumentsMigration.migrate(in: db)
                }
            }
            if !applied.contains("v49_workspaceImportDestinations") { try createImportDestinations(in: db) }
            if !applied.contains("v50_syncPriority") { try SyncPriorityMigration.migrate(in: db) }
            if !applied.contains("v51_scopedSyncReconciliation") { try createReconciliations(in: db) }
        }
    }

    private static func createImportDestinations(in db: Database) throws {

        try db.execute(sql: """
        CREATE TABLE workspace_import_destinations (
            sourceWorkspaceId TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            connectionId TEXT NOT NULL REFERENCES dahlia_account_connections(id) ON DELETE CASCADE,
            organizationId TEXT NOT NULL,
            name TEXT NOT NULL,
            destinationWorkspaceId TEXT NOT NULL UNIQUE,
            requestJSON BLOB NOT NULL,
            PRIMARY KEY (sourceWorkspaceId, connectionId, organizationId, name)
        )
        """)
    }

    private static func createReconciliations(in db: Database) throws {

        guard try db.tableExists("workspaces") else { return }
        try db.execute(sql: """
        CREATE TABLE sync_reconciliations (
            workspaceId BLOB NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            connectionId BLOB NOT NULL REFERENCES dahlia_account_connections(id) ON DELETE CASCADE,
            entity TEXT NOT NULL, entityId BLOB NOT NULL, includeDescendants BOOLEAN NOT NULL DEFAULT 0,
            PRIMARY KEY(workspaceId, entity, entityId)
        );
        CREATE TRIGGER sync_reconciliation_connection AFTER UPDATE OF accountConnectionId ON workspaces
        WHEN OLD.accountConnectionId IS NOT NEW.accountConnectionId
        BEGIN
            DELETE FROM sync_reconciliations WHERE workspaceId = NEW.id;
        END;
        """)
    }
}
