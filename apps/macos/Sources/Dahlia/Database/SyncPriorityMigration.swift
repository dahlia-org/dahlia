import Foundation
import GRDB

/// Part of the unreleased Documents/sync migration. Existing operations remain barriers until their immutable inputs are indexed.
enum SyncPriorityMigration {
    static func migrate(in db: Database) throws {
        // Some historical migration fixtures deliberately contain only their affected tables.
        guard try db.tableExists("sync_transactions"), try db.tableExists("workspaces") else { return }
        for (table, name) in [
            ("workspaces", "syncLifecycleGeneration"),
            ("sync_transactions", "syncPriority"),
            ("sync_transactions", "dependenciesReady"),
        ] where try !db.columns(in: table).contains(where: { $0.name == name }) {
            try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(name) INTEGER NOT NULL DEFAULT 0")
        }
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS sync_transactions_blocked_workspace ON sync_transactions(workspace_id, blockedReason);
        CREATE INDEX IF NOT EXISTS sync_dependencies_backfill ON sync_transactions(dependenciesReady, workspace_id, sequence);
        CREATE TABLE IF NOT EXISTS sync_dependency_keys (
            transactionId TEXT NOT NULL REFERENCES sync_transactions(id) ON DELETE CASCADE,
            resource TEXT NOT NULL,
            exclusive INTEGER NOT NULL,
            PRIMARY KEY (transactionId, resource)
        );
        CREATE INDEX IF NOT EXISTS sync_dependency_resource ON sync_dependency_keys(resource, exclusive, transactionId);
        CREATE TABLE IF NOT EXISTS sync_dependencies (
            transactionId TEXT NOT NULL REFERENCES sync_transactions(id) ON DELETE CASCADE,
            predecessorId TEXT NOT NULL REFERENCES sync_transactions(id) ON DELETE CASCADE,
            provisional INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (transactionId, predecessorId)
        );
        CREATE INDEX IF NOT EXISTS sync_dependency_predecessor ON sync_dependencies(predecessorId, transactionId);
        CREATE TABLE IF NOT EXISTS sync_relation_history (
            entity TEXT NOT NULL, entityId TEXT NOT NULL, workspaceId TEXT NOT NULL,
            projectId TEXT, meetingId TEXT, fileId TEXT,
            PRIMARY KEY (entity, entityId, workspaceId, projectId, meetingId, fileId)
        );
        CREATE INDEX IF NOT EXISTS sync_relation_identity ON sync_relation_history(entity, entityId);
        CREATE TABLE IF NOT EXISTS sync_confirmed_relations (
            workspaceId TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            entity TEXT NOT NULL, entityId TEXT NOT NULL,
            projectId TEXT, meetingId TEXT, fileId TEXT,
            PRIMARY KEY (workspaceId, entity, entityId)
        );
        CREATE TABLE IF NOT EXISTS sync_initial_builds (
            id BLOB PRIMARY KEY NOT NULL,
            workspaceId BLOB NOT NULL UNIQUE REFERENCES workspaces(id) ON DELETE CASCADE,
            connectionId BLOB NOT NULL REFERENCES dahlia_account_connections(id) ON DELETE CASCADE,
            restoring BOOLEAN NOT NULL, replaceImages BOOLEAN NOT NULL DEFAULT 0,
            importId BLOB REFERENCES local_workspace_imports(id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS sync_initial_entities (
            workspaceId BLOB NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
            entity TEXT NOT NULL, entityId BLOB NOT NULL, resource TEXT NOT NULL, built BOOLEAN NOT NULL DEFAULT 0,
            priority INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(workspaceId, entity, entityId)
        );
        CREATE INDEX IF NOT EXISTS sync_initial_resource ON sync_initial_entities(resource, built);
        CREATE INDEX IF NOT EXISTS sync_initial_pending ON sync_initial_entities(workspaceId, built, priority, entity);
        CREATE TABLE IF NOT EXISTS sync_scheduler_state (
            id INTEGER PRIMARY KEY CHECK(id = 1), foregroundCount INTEGER NOT NULL DEFAULT 0,
            lastWorkspace TEXT
        );
        INSERT OR IGNORE INTO sync_scheduler_state(id) VALUES (1);
        CREATE TRIGGER IF NOT EXISTS sync_lifecycle_reset AFTER INSERT ON sync_operations
        WHEN NEW.entity = 'workspace' AND NEW.action = 'reset'
        BEGIN
            UPDATE workspaces SET syncLifecycleGeneration = syncLifecycleGeneration + 1
            WHERE id = (SELECT workspace_id FROM sync_transactions WHERE id = NEW.transactionId);
        END;
        CREATE TRIGGER IF NOT EXISTS sync_lifecycle_workspace AFTER UPDATE OF accountConnectionId, syncConfirmedConnectionId, syncRole, syncRecoveryState ON workspaces
        WHEN OLD.accountConnectionId IS NOT NEW.accountConnectionId
          OR OLD.syncConfirmedConnectionId IS NOT NEW.syncConfirmedConnectionId
          OR OLD.syncRole IS NOT NEW.syncRole OR OLD.syncRecoveryState IS NOT NEW.syncRecoveryState
        BEGIN
            UPDATE workspaces SET syncLifecycleGeneration = syncLifecycleGeneration + 1 WHERE id = NEW.id;
        END;
        CREATE TRIGGER IF NOT EXISTS sync_initial_connection AFTER UPDATE OF accountConnectionId ON workspaces
        WHEN OLD.accountConnectionId IS NOT NEW.accountConnectionId
        BEGIN
            DELETE FROM sync_initial_builds WHERE workspaceId = NEW.id;
            DELETE FROM sync_initial_entities WHERE workspaceId = NEW.id;
        END;
        CREATE TRIGGER IF NOT EXISTS sync_lifecycle_meeting AFTER UPDATE OF workspace_id ON meetings
        WHEN OLD.workspace_id IS NOT NEW.workspace_id
        BEGIN
            UPDATE workspaces SET syncLifecycleGeneration = syncLifecycleGeneration + 1 WHERE id IN (OLD.workspace_id, NEW.workspace_id);
        END;
        """)
        // BEFORE triggers capture relations even when a caller updates the row before recording its operation.
        // No content is copied. The recorder consumes this journal in the same local transaction.
        for action in ["UPDATE", "DELETE"] {
            for (table, entity, workspace, project, meeting, file) in [
                ("projects", "project", "OLD.workspace_id", "OLD.parentProjectId", "NULL", "NULL"),
                ("meetings", "meeting", "OLD.workspace_id", "OLD.projectId", "NULL", "NULL"),
                (
                    "meeting_attachments",
                    "meeting_attachment",
                    "(SELECT workspace_id FROM meetings WHERE id = OLD.meetingId)",
                    "NULL",
                    "OLD.meetingId",
                    "OLD.fileId"
                ),
            ] {
                try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS sync_old_\(entity)_\(action.lowercased()) BEFORE \(action) ON \(table)
                BEGIN
                    INSERT INTO sync_relation_history(entity, entityId, workspaceId, projectId, meetingId, fileId)
                    SELECT '\(entity)', OLD.id, \(workspace), \(project), \(meeting), \(file)
                    WHERE \(workspace) IS NOT NULL
                      AND NOT EXISTS (SELECT 1 FROM sync_relation_history WHERE entity = '\(entity)' AND entityId = OLD.id
                          AND workspaceId IS \(workspace) AND projectId IS \(project) AND meetingId IS \(meeting) AND fileId IS \(file));
                END;
                """)
            }
        }
    }
}
