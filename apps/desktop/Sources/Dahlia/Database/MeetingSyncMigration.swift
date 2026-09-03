import GRDB

let syncQueueTransactionIDSQL = """
lower(
    substr(printf('%012x', CAST(unixepoch('subsec') * 1000 AS INTEGER)), 1, 8) || '-' ||
    substr(printf('%012x', CAST(unixepoch('subsec') * 1000 AS INTEGER)), 9, 4) ||
    '-7' || substr(hex(randomblob(2)), 2, 3) || '-8' ||
    substr(hex(randomblob(2)), 2, 3) || '-' || hex(randomblob(6))
)
"""

enum MeetingSyncMigration {
    static func migrate(in db: Database) throws {
        guard try ["vaults", "meetings", "summaries", "screenshots", "transcript_segments"]
            .allSatisfy({ try db.tableExists($0) }) else { return }
        try db.alter(table: VaultRecord.databaseTableName) { table in
            table.add(column: "syncEnabled", .boolean).notNull().defaults(to: false)
            table.add(column: "syncConfirmedConnectionId", .blob)
            table.add(column: "syncDeletionMode", .text)
            table.add(column: "syncDeletionApproved", .boolean).notNull().defaults(to: false)
            table.add(column: "serverRevision", .integer)
            table.add(column: "syncCursor", .text)
            table.add(column: "syncConflictJSON", .text)
            table.add(column: "syncBootstrapPending", .boolean).notNull().defaults(to: false)
        }
        try db.alter(table: MeetingRecord.databaseTableName) { table in
            table.add(column: "serverRevision", .integer)
            table.add(column: "summaryServerRevision", .integer).notNull().defaults(to: 0)
            table.add(column: "transcriptServerRevision", .integer).notNull().defaults(to: 0)
            table.add(column: "transcriptServerGeneration", .text)
        }
        try db.alter(table: SummaryRecord.databaseTableName) { table in
            table.add(column: "serverRevision", .integer).notNull().defaults(to: 0)
        }
        try db.alter(table: MeetingScreenshotRecord.databaseTableName) { table in
            table.add(column: "serverRevision", .integer)
        }
        try db.execute(sql: schemaSQL)
        try db.execute(sql: triggerSQL)
    }

    private static let schemaSQL = """
    CREATE TABLE sync_apply_context (
        active INTEGER PRIMARY KEY CHECK(active = 1)
    );
    CREATE TABLE cloud_vaults (
        vaultId BLOB NOT NULL,
        connectionId BLOB NOT NULL REFERENCES dahlia_account_connections(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        createdAt DATETIME NOT NULL,
        revision INTEGER NOT NULL,
        PRIMARY KEY(vaultId, connectionId)
    );
    CREATE TABLE meeting_sync_jobs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        vaultId BLOB NOT NULL,
        meetingId BLOB,
        targetKind TEXT NOT NULL CHECK(targetKind IN ('upload', 'meetingDelete')),
        transactionId TEXT NOT NULL DEFAULT (\(syncQueueTransactionIDSQL)),
        transactionCreatedAt DATETIME NOT NULL DEFAULT (unixepoch('subsec')),
        baseRevision INTEGER,
        generation INTEGER NOT NULL DEFAULT 1,
        segmentCount INTEGER,
        maxSegmentId BLOB,
        confirmedCount INTEGER,
        recordingEndedAt DATETIME,
        batchCompletedAt DATETIME,
        status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'running', 'failed')),
        attempts INTEGER NOT NULL DEFAULT 0,
        availableAt DATETIME NOT NULL DEFAULT (unixepoch('subsec')),
        claimedAt DATETIME,
        leaseExpiresAt DATETIME,
        lastErrorCode TEXT,
        updatedAt DATETIME NOT NULL DEFAULT (unixepoch('subsec')),
        UNIQUE(targetKind, meetingId)
    );
    CREATE INDEX meeting_sync_jobs_on_status_availableAt
    ON meeting_sync_jobs(status, availableAt, id);
    CREATE INDEX meeting_sync_jobs_on_vaultId
    ON meeting_sync_jobs(vaultId, targetKind, id);
    """

    /// Meeting-level coalescing deliberately excludes transcript inserts from the recording write path.
    private static let triggerSQL = """
    CREATE TRIGGER meeting_sync_queue_meeting_insert AFTER INSERT ON meetings
    WHEN NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        VALUES(new.vaultId, new.id, 'upload')
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET
            generation = generation + 1, transactionId = \(
                syncQueueTransactionIDSQL
            ), transactionCreatedAt = unixepoch('subsec'), status = 'pending', attempts = 0,
            availableAt = unixepoch('subsec'), claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_meeting_update
    AFTER UPDATE OF name, description, status, duration, recordingStartedAt, createdAt ON meetings
    WHEN NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        VALUES(new.vaultId, new.id, 'upload')
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET
            generation = generation + 1, transactionId = \(
                syncQueueTransactionIDSQL
            ), transactionCreatedAt = unixepoch('subsec'), vaultId = excluded.vaultId, status = 'pending', attempts = 0,
            availableAt = unixepoch('subsec'), claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_meeting_delete AFTER DELETE ON meetings
    WHEN NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        DELETE FROM meeting_sync_jobs WHERE targetKind = 'upload' AND meetingId = old.id;
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind, baseRevision)
        VALUES(old.vaultId, old.id, 'meetingDelete', old.serverRevision)
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET
            generation = generation + 1, transactionId = \(syncQueueTransactionIDSQL),
            transactionCreatedAt = unixepoch('subsec'), baseRevision = old.serverRevision,
            vaultId = excluded.vaultId, status = 'pending', attempts = 0,
            availableAt = unixepoch('subsec'), claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_summary_insert AFTER INSERT ON summaries
    WHEN NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT vaultId, new.meetingId, 'upload' FROM meetings WHERE id = new.meetingId
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            transactionId = \(syncQueueTransactionIDSQL), transactionCreatedAt = unixepoch('subsec'),
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_summary_update AFTER UPDATE OF title, document, createdAt ON summaries
    WHEN NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT vaultId, new.meetingId, 'upload' FROM meetings WHERE id = new.meetingId
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            transactionId = \(syncQueueTransactionIDSQL), transactionCreatedAt = unixepoch('subsec'),
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_summary_delete AFTER DELETE ON summaries
    WHEN NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT vaultId, old.meetingId, 'upload' FROM meetings WHERE id = old.meetingId
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            transactionId = \(syncQueueTransactionIDSQL), transactionCreatedAt = unixepoch('subsec'),
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_screenshot_insert AFTER INSERT ON screenshots
    WHEN NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT vaultId, new.meetingId, 'upload' FROM meetings WHERE id = new.meetingId
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            transactionId = \(syncQueueTransactionIDSQL), transactionCreatedAt = unixepoch('subsec'),
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_screenshot_analysis
    AFTER UPDATE OF ocrText, caption ON screenshots
    WHEN NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT vaultId, new.meetingId, 'upload' FROM meetings WHERE id = new.meetingId
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            transactionId = \(syncQueueTransactionIDSQL), transactionCreatedAt = unixepoch('subsec'),
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_screenshot_delete AFTER DELETE ON screenshots
    WHEN NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT vaultId, old.meetingId, 'upload' FROM meetings WHERE id = old.meetingId
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            transactionId = \(syncQueueTransactionIDSQL), transactionCreatedAt = unixepoch('subsec'),
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_vault_enable AFTER UPDATE OF syncEnabled ON vaults
    WHEN old.syncEnabled = 0 AND new.syncEnabled = 1
      AND NOT EXISTS (SELECT 1 FROM sync_apply_context) BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT new.id, id, 'upload' FROM meetings WHERE vaultId = new.id
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            transactionId = \(syncQueueTransactionIDSQL), transactionCreatedAt = unixepoch('subsec'),
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    """
}
