import GRDB

/// Frozen development schemas used only to validate old backups before any migration or trigger can execute.
enum DevelopmentSchemaHistory {
    static func migrator(for identifier: String) -> DatabaseMigrator {
        guard ["v52_documentsAndSync", "v53_sharedBackgroundJobs", "v53_documentsSyncAndBackgroundJobs"].contains(identifier) else { return migrator }
        var migrator = AppDatabaseManager.releasedMigrator
        migrator.registerMigration("v52_documentsAndSync") { db in
            try FrozenDocumentsMigration.migrate(in: db)
            try DocumentsAndSyncMigration.migrateDocumentsAndSync(in: db, applied: ["v48_independentDocuments"])
        }
        migrator.registerMigration("v53_sharedBackgroundJobs") { db in
            try BackgroundJobsMigration.migrate(in: db)
        }
        if identifier == "v53_documentsSyncAndBackgroundJobs" {
            var consolidated = AppDatabaseManager.releasedMigrator
            consolidated.registerMigration(identifier) { db in
                try FrozenDocumentsMigration.migrate(in: db)
                try DocumentsAndSyncMigration.migrateDocumentsAndSync(in: db, applied: ["v48_independentDocuments"])
                try BackgroundJobsMigration.migrate(in: db)
            }
            return consolidated
        }
        return migrator
    }

    static var migrator: DatabaseMigrator {
        var migrator = AppDatabaseManager.releasedMigrator
        // Both v47 identifiers were registered independently. Keep their complete names and bodies unchanged.
        migrator.registerMigration("v47_documents") { db in
            try LegacyDocumentsMigration.migrate(in: db)
        }

        migrator.registerMigration("v48_independentDocuments", foreignKeyChecks: .deferred) { db in
            try IndependentDocumentsMigration.migrate(in: db)
        }

        migrator.registerMigration("v49_workspaceImportDestinations") { db in
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

        migrator.registerMigration("v50_syncPriority") { db in
            try SyncPriorityMigration.migrate(in: db)
        }

        migrator.registerMigration("v51_scopedSyncReconciliation") { db in
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

        // v52 consolidated the same final Documents/sync schema represented above.
        migrator.registerMigration("v52_documentsAndSync") { _ in }
        migrator.registerMigration("v53_sharedBackgroundJobs") { db in
            try BackgroundJobsMigration.migrate(in: db)
        }

        return migrator
    }
}

private enum LegacyDocumentsMigration {
    static func migrate(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE documents (
            id BLOB PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            meetingId BLOB NOT NULL UNIQUE REFERENCES meetings(id) ON DELETE CASCADE,
            schemaVersion INTEGER NOT NULL DEFAULT 1,
            revision INTEGER NOT NULL DEFAULT 0,
            generation BLOB,
            checkpoint TEXT NOT NULL,
            checkpointSequence INTEGER NOT NULL DEFAULT 0,
            projectionSequence INTEGER NOT NULL DEFAULT 0,
            text TEXT NOT NULL DEFAULT '',
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            lastAccessedAt DATETIME,
            resident BOOLEAN NOT NULL DEFAULT 1,
            locallyEdited BOOLEAN NOT NULL DEFAULT 0,
            CHECK (id = meetingId)
        );
        CREATE TABLE document_updates (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            meetingId BLOB NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            payload TEXT NOT NULL,
            pending BOOLEAN NOT NULL,
            createdAt DATETIME NOT NULL
        );
        CREATE INDEX document_updates_meeting ON document_updates(meetingId, id);
        CREATE INDEX document_updates_pending ON document_updates(pending, meetingId);
        CREATE TABLE document_recoveries (
            id BLOB PRIMARY KEY NOT NULL,
            meetingId BLOB NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            blocksJSON TEXT NOT NULL,
            reason TEXT NOT NULL,
            pending BOOLEAN NOT NULL DEFAULT 0,
            createdAt DATETIME NOT NULL
        );
        CREATE TABLE document_private_copies (
            id BLOB PRIMARY KEY NOT NULL,
            meetingId BLOB NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            checkpoint TEXT NOT NULL,
            text TEXT NOT NULL,
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL
        );
        CREATE TABLE document_local_archives (
            id BLOB PRIMARY KEY NOT NULL,
            workspace_id BLOB NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            meetingId BLOB NOT NULL,
            name TEXT NOT NULL,
            payload TEXT NOT NULL,
            createdAt DATETIME NOT NULL
        );
        CREATE TABLE document_legacy_imports (
            meetingId BLOB PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            importedAt DATETIME NOT NULL
        );
        """)
    }
}

/// Creates the final document schema directly for released databases and fresh installations.
private enum FrozenDocumentsMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists("meetings"), try db.tableExists("workspaces"),
              try db.columns(in: "meetings").contains(where: { $0.name == "workspace_id" }) else { return }
        try db.execute(sql: """
        CREATE TABLE document_legacy_imports (
            meetingId BLOB PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            importedAt DATETIME NOT NULL
        );
        CREATE TABLE "document_local_archives" (
            id BLOB PRIMARY KEY NOT NULL,
            workspace_id BLOB NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            meetingId BLOB,
            name TEXT NOT NULL, payload TEXT NOT NULL, createdAt DATETIME NOT NULL
        );
        CREATE TABLE "document_private_copies" (
            id BLOB PRIMARY KEY NOT NULL,
            workspace_id BLOB NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            meetingId BLOB,
            kind TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
            checkpoint TEXT NOT NULL, text TEXT NOT NULL, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL,
            FOREIGN KEY (workspace_id, meetingId) REFERENCES meetings(workspace_id, id) ON DELETE CASCADE ON UPDATE CASCADE
        );
        CREATE TABLE "document_recoveries" (
            id BLOB PRIMARY KEY NOT NULL,
            documentId BLOB NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
            blocksJSON TEXT NOT NULL, reason TEXT NOT NULL, pending BOOLEAN NOT NULL DEFAULT 0, createdAt DATETIME NOT NULL
        );
        CREATE TABLE "document_updates" (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            documentId BLOB NOT NULL REFERENCES documents(id) ON DELETE CASCADE ON UPDATE CASCADE,
            payload TEXT NOT NULL, pending BOOLEAN NOT NULL, createdAt DATETIME NOT NULL
        );
        CREATE TABLE "documents" (
            id BLOB PRIMARY KEY NOT NULL,
            workspace_id BLOB NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            meetingId BLOB,
            kind TEXT NOT NULL CHECK (kind IN ('notes', 'summary', 'general')),
            title TEXT NOT NULL DEFAULT '',
            schemaVersion INTEGER NOT NULL DEFAULT 1,
            revision INTEGER NOT NULL DEFAULT 0,
            generation BLOB,
            checkpoint TEXT NOT NULL,
            checkpointSequence INTEGER NOT NULL DEFAULT 0,
            projectionSequence INTEGER NOT NULL DEFAULT 0,
            text TEXT NOT NULL DEFAULT '',
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL,
            lastAccessedAt DATETIME,
            resident BOOLEAN NOT NULL DEFAULT 1,
            locallyEdited BOOLEAN NOT NULL DEFAULT 0,
            CHECK (kind != 'notes' OR meetingId IS NOT NULL),
            FOREIGN KEY (workspace_id, meetingId) REFERENCES meetings(workspace_id, id) ON DELETE CASCADE ON UPDATE CASCADE
        );
        CREATE UNIQUE INDEX document_meeting_notes_unique ON documents(meetingId) WHERE kind = 'notes';
        CREATE INDEX document_updates_document ON document_updates(documentId, id);
        CREATE INDEX document_updates_pending ON document_updates(pending, documentId);
        CREATE INDEX documents_workspace ON documents(workspace_id, id);
        CREATE UNIQUE INDEX meetings_workspace_identity ON meetings(workspace_id, id);
        """)
    }
}
