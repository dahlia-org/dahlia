import GRDB

enum VaultProjectSyncMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists("transcript_segments") else { return }
        let transcriptColumns = try db.columns(in: "transcript_segments")
        if !transcriptColumns.contains(where: { $0.name == "audioSource" }) {
            try db.alter(table: "transcript_segments") { table in
                table.add(column: "audioSource", .text)
            }
            try db.execute(sql: "UPDATE transcript_segments SET audioSource = speakerLabel, speakerLabel = NULL")
        }
        guard try ["vaults", "projects", "meetings"].allSatisfy({ try db.tableExists($0) }) else { return }
        try db.alter(table: ProjectRecord.databaseTableName) { table in
            table.add(column: "serverRevision", .integer)
        }
        try db.execute(sql: schemaSQL)
        try db.execute(sql: triggerSQL)
    }

    private static let schemaSQL = """
    CREATE TABLE vault_sync_jobs (
        vaultId BLOB NOT NULL PRIMARY KEY REFERENCES vaults(id) ON DELETE CASCADE,
        transactionId TEXT NOT NULL DEFAULT (\(syncQueueTransactionIDSQL)),
        transactionCreatedAt DATETIME NOT NULL DEFAULT (unixepoch('subsec')),
        generation INTEGER NOT NULL DEFAULT 1,
        status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'running', 'failed')),
        attempts INTEGER NOT NULL DEFAULT 0,
        availableAt DATETIME NOT NULL DEFAULT (unixepoch('subsec')),
        claimedAt DATETIME,
        leaseExpiresAt DATETIME,
        lastErrorCode TEXT,
        updatedAt DATETIME NOT NULL DEFAULT (unixepoch('subsec'))
    );
    CREATE INDEX vault_sync_jobs_on_status_availableAt
    ON vault_sync_jobs(status, availableAt, vaultId);
    """

    private static let triggerSQL = """
    CREATE TRIGGER vault_sync_queue_vault_name AFTER UPDATE OF name ON vaults
    WHEN new.syncEnabled = 1 AND NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO vault_sync_jobs(vaultId) VALUES(new.id)
        ON CONFLICT(vaultId) DO UPDATE SET generation = generation + 1, transactionId = \(
            syncQueueTransactionIDSQL
        ), transactionCreatedAt = unixepoch('subsec'), status = 'pending', attempts = 0,
            availableAt = unixepoch('subsec'), claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER vault_sync_queue_vault_enable AFTER UPDATE OF syncEnabled ON vaults
    WHEN old.syncEnabled = 0 AND new.syncEnabled = 1
      AND NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO vault_sync_jobs(vaultId) VALUES(new.id)
        ON CONFLICT(vaultId) DO UPDATE SET generation = generation + 1, transactionId = \(
            syncQueueTransactionIDSQL
        ), transactionCreatedAt = unixepoch('subsec'), status = 'pending', attempts = 0,
            availableAt = unixepoch('subsec'), claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER vault_sync_queue_project_insert AFTER INSERT ON projects
    WHEN NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO vault_sync_jobs(vaultId) SELECT new.vaultId WHERE EXISTS (
            SELECT 1 FROM vaults WHERE id = new.vaultId AND syncEnabled = 1
        ) ON CONFLICT(vaultId) DO UPDATE SET generation = generation + 1, transactionId = \(
            syncQueueTransactionIDSQL
        ), transactionCreatedAt = unixepoch('subsec'), status = 'pending', attempts = 0,
            availableAt = unixepoch('subsec'), claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER vault_sync_queue_project_update
    AFTER UPDATE OF vaultId, parentProjectId, name, description, projectType, revision ON projects
    WHEN NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO vault_sync_jobs(vaultId) SELECT old.vaultId WHERE EXISTS (
            SELECT 1 FROM vaults WHERE id = old.vaultId AND syncEnabled = 1
        ) ON CONFLICT(vaultId) DO UPDATE SET generation = generation + 1, transactionId = \(
            syncQueueTransactionIDSQL
        ), transactionCreatedAt = unixepoch('subsec'), status = 'pending', attempts = 0,
            availableAt = unixepoch('subsec'), claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = unixepoch('subsec');
        INSERT INTO vault_sync_jobs(vaultId) SELECT new.vaultId WHERE EXISTS (
            SELECT 1 FROM vaults WHERE id = new.vaultId AND syncEnabled = 1
        ) ON CONFLICT(vaultId) DO UPDATE SET generation = generation + 1, transactionId = \(
            syncQueueTransactionIDSQL
        ), transactionCreatedAt = unixepoch('subsec'), status = 'pending', attempts = 0,
            availableAt = unixepoch('subsec'), claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER vault_sync_queue_project_delete AFTER DELETE ON projects
    WHEN NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO vault_sync_jobs(vaultId) SELECT old.vaultId WHERE EXISTS (
            SELECT 1 FROM vaults WHERE id = old.vaultId AND syncEnabled = 1
        ) ON CONFLICT(vaultId) DO UPDATE SET generation = generation + 1, transactionId = \(
            syncQueueTransactionIDSQL
        ), transactionCreatedAt = unixepoch('subsec'), status = 'pending', attempts = 0,
            availableAt = unixepoch('subsec'), claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_project_assignment
    AFTER UPDATE OF projectId ON meetings
    WHEN NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT new.vaultId, new.id, 'upload' WHERE EXISTS (
            SELECT 1 FROM vaults WHERE id = new.vaultId AND syncEnabled = 1
        ) ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            transactionId = \(syncQueueTransactionIDSQL), transactionCreatedAt = unixepoch('subsec'),
            vaultId = excluded.vaultId, status = 'pending', attempts = 0,
            availableAt = unixepoch('subsec'), claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    """
}
