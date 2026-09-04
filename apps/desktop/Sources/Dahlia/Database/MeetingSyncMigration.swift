import GRDB

/// Final unreleased synchronization schema. v1-v41 are the only published migrations.
enum MeetingSyncMigration {
    static func migrate(in db: Database) throws {
        guard try ["vaults", "meetings", "screenshots", "transcript_segments", "dahlia_account_connections"]
            .allSatisfy({ try db.tableExists($0) }) else { return }

        try db.alter(table: VaultRecord.databaseTableName) { table in
            table.add(column: "syncEnabled", .boolean).notNull().defaults(to: false)
            table.add(column: "syncRole", .text).check { $0 == nil || ["owner", "member"].contains($0) }
            table.add(column: "syncConfirmedConnectionId", .blob)
            table.add(column: "syncPullCursor", .text)
            table.add(column: "syncLastCommittedCursor", .text)
        }
        try db.alter(table: TranscriptSegmentRecord.databaseTableName) { table in
            table.add(column: "audioSource", .text)
        }
        try db.execute(sql: "UPDATE transcript_segments SET audioSource = speakerLabel, speakerLabel = NULL")
        try db.execute(sql: schemaSQL)
    }

    private static let schemaSQL = """
    CREATE TABLE sync_transactions (
        sequence INTEGER PRIMARY KEY,
        id BLOB NOT NULL UNIQUE,
        vaultId BLOB NOT NULL,
        connectionId BLOB NOT NULL REFERENCES dahlia_account_connections(id),
        createdAt DATETIME NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        availableAt DATETIME NOT NULL,
        leaseExpiresAt DATETIME,
        blockedReason TEXT CHECK(blockedReason IN ('validation', 'conflict', 'authorization')),
        serverResponseJSON TEXT
    );
    CREATE INDEX sync_transactions_claim_idx
        ON sync_transactions(blockedReason, availableAt, leaseExpiresAt, sequence);
    CREATE INDEX sync_transactions_vault_sequence_idx
        ON sync_transactions(vaultId, sequence);

    CREATE TABLE sync_operations (
        transactionId BLOB NOT NULL REFERENCES sync_transactions(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        id BLOB NOT NULL UNIQUE,
        entity TEXT NOT NULL CHECK(entity IN ('vault', 'project', 'meeting', 'summary', 'transcript', 'screenshot')),
        action TEXT NOT NULL CHECK(action IN ('create', 'update', 'delete', 'upsert', 'patch', 'reset')),
        entityId BLOB NOT NULL,
        baseRevision INTEGER,
        payloadJSON TEXT,
        attachmentMimeType TEXT,
        attachmentSHA256 TEXT CHECK(attachmentSHA256 IS NULL OR length(attachmentSHA256) = 64),
        attachmentBytes BLOB,
        PRIMARY KEY(transactionId, position),
        UNIQUE(transactionId, entity, entityId),
        CHECK(
            (attachmentMimeType IS NULL AND attachmentSHA256 IS NULL AND attachmentBytes IS NULL)
            OR (entity = 'screenshot' AND attachmentMimeType IS NOT NULL
                AND attachmentSHA256 IS NOT NULL)
        )
    );
    CREATE INDEX sync_operations_entity_idx
        ON sync_operations(entity, entityId, transactionId);

    CREATE TRIGGER sync_screenshot_attachment_before_update
    BEFORE UPDATE OF imageData, mimeType ON screenshots
    BEGIN
        UPDATE sync_operations
        SET attachmentBytes = OLD.imageData
        WHERE entity = 'screenshot' AND entityId = OLD.id
          AND attachmentMimeType IS NOT NULL AND attachmentBytes IS NULL;
    END;

    CREATE TRIGGER sync_screenshot_attachment_before_delete
    BEFORE DELETE ON screenshots
    BEGIN
        UPDATE sync_operations
        SET attachmentBytes = OLD.imageData
        WHERE entity = 'screenshot' AND entityId = OLD.id
          AND attachmentMimeType IS NOT NULL AND attachmentBytes IS NULL;
    END;

    CREATE TABLE sync_entity_state (
        vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
        entity TEXT NOT NULL,
        entityId BLOB NOT NULL,
        confirmedRevision INTEGER,
        PRIMARY KEY(vaultId, entity, entityId)
    );

    CREATE TABLE sync_transcript_patch_items (
        operationId BLOB NOT NULL REFERENCES sync_operations(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        action TEXT NOT NULL CHECK(action IN ('upsert', 'delete')),
        segmentId BLOB NOT NULL,
        startTime DATETIME,
        endTime DATETIME,
        text TEXT,
        isConfirmed INTEGER,
        audioSource TEXT,
        speakerLabel TEXT,
        PRIMARY KEY(operationId, position),
        UNIQUE(operationId, segmentId),
        CHECK(
            (action = 'delete' AND startTime IS NULL AND endTime IS NULL AND text IS NULL
                AND isConfirmed IS NULL AND audioSource IS NULL AND speakerLabel IS NULL)
            OR (action = 'upsert' AND startTime IS NOT NULL AND text IS NOT NULL
                AND isConfirmed IS NOT NULL)
        )
    );
    """
}
