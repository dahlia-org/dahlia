import GRDB

enum MeetingSyncMigration {
    static func migrate(in db: Database) throws {
        guard try ["vaults", "meetings", "summaries", "screenshots", "transcript_segments"]
            .allSatisfy({ try db.tableExists($0) }) else { return }
        try db.alter(table: VaultRecord.databaseTableName) { table in
            table.add(column: "syncEnabled", .boolean).notNull().defaults(to: false)
            table.add(column: "syncConfirmedConnectionId", .blob)
            table.add(column: "syncDeletionMode", .text)
            table.add(column: "syncDeletionApproved", .boolean).notNull().defaults(to: false)
        }
        try db.execute(sql: schemaSQL)
        try db.execute(sql: triggerSQL)
    }

    private static let schemaSQL = """
    CREATE TABLE meeting_sync_jobs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        vaultId BLOB NOT NULL,
        meetingId BLOB,
        targetKind TEXT NOT NULL CHECK(targetKind IN ('upload', 'meetingDelete')),
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
    CREATE TRIGGER meeting_sync_queue_meeting_insert AFTER INSERT ON meetings BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        VALUES(new.vaultId, new.id, 'upload')
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET
            generation = generation + 1, status = 'pending', attempts = 0,
            availableAt = unixepoch('subsec'), claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_meeting_update
    AFTER UPDATE OF name, description, status, duration, recordingStartedAt, createdAt ON meetings BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        VALUES(new.vaultId, new.id, 'upload')
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET
            generation = generation + 1, vaultId = excluded.vaultId, status = 'pending', attempts = 0,
            availableAt = unixepoch('subsec'), claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_meeting_delete AFTER DELETE ON meetings BEGIN
        DELETE FROM meeting_sync_jobs WHERE targetKind = 'upload' AND meetingId = old.id;
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        VALUES(old.vaultId, old.id, 'meetingDelete')
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET
            generation = generation + 1, vaultId = excluded.vaultId, status = 'pending', attempts = 0,
            availableAt = unixepoch('subsec'), claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_summary_insert AFTER INSERT ON summaries BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT vaultId, new.meetingId, 'upload' FROM meetings WHERE id = new.meetingId
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_summary_update AFTER UPDATE OF title, document, createdAt ON summaries BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT vaultId, new.meetingId, 'upload' FROM meetings WHERE id = new.meetingId
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_summary_delete AFTER DELETE ON summaries BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT vaultId, old.meetingId, 'upload' FROM meetings WHERE id = old.meetingId
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_screenshot_insert AFTER INSERT ON screenshots BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT vaultId, new.meetingId, 'upload' FROM meetings WHERE id = new.meetingId
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_screenshot_analysis
    AFTER UPDATE OF ocrText, caption ON screenshots BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT vaultId, new.meetingId, 'upload' FROM meetings WHERE id = new.meetingId
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_screenshot_delete AFTER DELETE ON screenshots BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT vaultId, old.meetingId, 'upload' FROM meetings WHERE id = old.meetingId
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    CREATE TRIGGER meeting_sync_queue_vault_enable AFTER UPDATE OF syncEnabled ON vaults
    WHEN old.syncEnabled = 0 AND new.syncEnabled = 1 BEGIN
        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
        SELECT new.id, id, 'upload' FROM meetings WHERE vaultId = new.id
        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'), claimedAt = NULL,
            leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = unixepoch('subsec');
    END;
    """
}
