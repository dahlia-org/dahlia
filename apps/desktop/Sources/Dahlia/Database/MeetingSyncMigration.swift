import Foundation
import GRDB

/// Final unreleased synchronization schema. v1-v41 are the only published migrations.
enum MeetingSyncMigration {
    static func migrate(in db: Database, defaults: UserDefaults = .standard) throws {
        guard try ["vaults", "meetings", "screenshots", "transcript_segments", "dahlia_account_connections"]
            .allSatisfy({ try db.tableExists($0) }) else { return }

        try migrateVault(in: db, defaults: defaults)
        try db.alter(table: TranscriptSegmentRecord.databaseTableName) { table in
            table.add(column: "audioSource", .text)
        }
        try db.execute(sql: "UPDATE transcript_segments SET audioSource = speakerLabel, speakerLabel = NULL")
        try db.execute(sql: "DROP INDEX IF EXISTS projects_unique_root_name")
        try db.execute(sql: "DROP INDEX IF EXISTS projects_unique_child_name")
        try db.execute(sql: schemaSQL)
    }

    private static func migrateVault(in db: Database, defaults: UserDefaults) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let generationDefaults = try String(decoding: encoder.encode(WorkspaceGenerationSettings()), as: UTF8.self)
        var settings = WorkspaceGenerationSettings()
        settings.outputLanguage = defaults.string(forKey: "llmSummaryLanguage")
            .flatMap(SummaryLanguage.init(rawValue:)) ?? .ja
        if let detail = defaults.string(forKey: "summaryDetailLevel") {
            settings.summary.style = SummaryStyle(detailLevel: .fromPersistedValue(detail))
        }
        settings.automaticProcessing = defaults.object(forKey: "automaticRecordingProcessingEnabled") as? Bool
            ?? defaults.object(forKey: "generateSummaryAfterBatchTranscription") as? Bool ?? true
        let inheritedSettings = try String(decoding: encoder.encode(settings), as: UTF8.self)
        // Published connections selected an AI account, not canonical Server ownership.
        // Keep account credentials and AI settings; Server association requires explicit Organization selection.
        try db.execute(sql: """
        CREATE TABLE vaults_v42 (
            id BLOB PRIMARY KEY,
            path TEXT UNIQUE,
            name TEXT NOT NULL,
            createdAt DATETIME NOT NULL,
            lastOpenedAt DATETIME NOT NULL,
            accountConnectionId BLOB REFERENCES dahlia_account_connections(id) ON DELETE SET NULL,
            localAIProvider TEXT NOT NULL DEFAULT 'chatGPTSubscription',
            databricksProfile TEXT NOT NULL DEFAULT '',
            generationSettings TEXT NOT NULL DEFAULT '\(generationDefaults.replacingOccurrences(of: "'", with: "''"))',
            chatModelID TEXT NOT NULL DEFAULT '',
            chatReasoningEffort TEXT NOT NULL DEFAULT 'medium',
            aiSettingsBackfilled INTEGER NOT NULL DEFAULT 0,
            organizationId BLOB,
            syncRole TEXT CHECK(syncRole IS NULL OR syncRole IN ('admin', 'editor', 'viewer')),
            syncConfirmedConnectionId BLOB,
            syncPullCursor TEXT,
            syncLastCommittedCursor TEXT,
            syncRecoveryState TEXT,
            syncMutationGeneration INTEGER NOT NULL DEFAULT 0,
            syncMeetingEventsVersion INTEGER NOT NULL DEFAULT 0,
            icon TEXT,
            color TEXT,
            CHECK ((accountConnectionId IS NULL AND organizationId IS NULL)
                OR (accountConnectionId IS NOT NULL AND organizationId IS NOT NULL))
        );
        INSERT INTO vaults_v42 (
            id, path, name, createdAt, lastOpenedAt, accountConnectionId,
            localAIProvider, databricksProfile, generationSettings,
            chatModelID, chatReasoningEffort, aiSettingsBackfilled
        )
        SELECT
            id, path, name, createdAt, lastOpenedAt, NULL,
            localAIProvider, databricksProfile,
            json_set(?, '$.local.model', summaryModelID, '$.local.reasoningEffort', summaryReasoningEffort),
            chatModelID, chatReasoningEffort, aiSettingsBackfilled
        FROM vaults;
        DROP TABLE vaults;
        ALTER TABLE vaults_v42 RENAME TO vaults;
        CREATE INDEX vaults_on_accountConnectionId ON vaults(accountConnectionId);
        """, arguments: [inheritedSettings])
        try SearchDocumentsMigration.createVaultCleanupTrigger(in: db)
    }

    private static let schemaSQL = """
    CREATE TABLE local_vault_imports (
        id BLOB PRIMARY KEY NOT NULL,
        sourceVaultId BLOB NOT NULL,
        destinationVaultId BLOB NOT NULL,
        connectionId BLOB NOT NULL,
        backupPath TEXT NOT NULL,
        createdAt DATETIME NOT NULL,
        completedAt DATETIME
    );
    CREATE TABLE local_vault_import_operations (
        operationId BLOB PRIMARY KEY NOT NULL,
        importId BLOB NOT NULL REFERENCES local_vault_imports(id),
        completedAt DATETIME,
        replacementOperationId BLOB
    );
    CREATE INDEX local_vault_import_operations_import ON local_vault_import_operations(importId, completedAt);

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

    CREATE TRIGGER sync_mutation_generation
    AFTER INSERT ON sync_transactions BEGIN
        UPDATE vaults SET syncMutationGeneration = syncMutationGeneration + 1
        WHERE id = NEW.vaultId;
    END;
    CREATE TRIGGER sync_association_generation
    AFTER UPDATE OF accountConnectionId, syncConfirmedConnectionId ON vaults
    WHEN NEW.accountConnectionId IS NOT OLD.accountConnectionId
        OR NEW.syncConfirmedConnectionId IS NOT OLD.syncConfirmedConnectionId
    BEGIN
        UPDATE vaults SET syncMutationGeneration = syncMutationGeneration + 1,
            syncRecoveryState = NULL WHERE id = NEW.id;
    END;
    CREATE TRIGGER sync_meeting_events_connection_change
    AFTER UPDATE OF accountConnectionId, syncConfirmedConnectionId ON vaults
    WHEN NEW.accountConnectionId IS NOT OLD.accountConnectionId
        OR NEW.syncConfirmedConnectionId IS NOT OLD.syncConfirmedConnectionId
    BEGIN
        UPDATE vaults SET syncMeetingEventsVersion = 0 WHERE id = NEW.id;
    END;

    CREATE TABLE sync_operations (
        transactionId BLOB NOT NULL REFERENCES sync_transactions(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        id BLOB NOT NULL UNIQUE,
        entity TEXT NOT NULL CHECK(entity IN ('workspace', 'project', 'meeting', 'summary', 'transcript', 'file', 'meeting_attachment', 'meeting_event', 'recording')),
        action TEXT NOT NULL CHECK(action IN ('create', 'update', 'delete', 'upsert', 'patch', 'reset')),
        entityId BLOB NOT NULL,
        baseRevision INTEGER,
        payloadJSON TEXT,
        attachmentMimeType TEXT,
        attachmentSHA256 TEXT CHECK(attachmentSHA256 IS NULL OR length(attachmentSHA256) = 64),
        attachmentBytes BLOB,
        attachmentReference TEXT,
        PRIMARY KEY(transactionId, position),
        UNIQUE(transactionId, entity, entityId),
        CHECK(
            (attachmentMimeType IS NULL AND attachmentSHA256 IS NULL AND attachmentBytes IS NULL)
            OR (entity = 'file' AND attachmentMimeType IS NOT NULL
                AND attachmentSHA256 IS NOT NULL)
        )
    );
    CREATE INDEX sync_operations_entity_idx
        ON sync_operations(entity, entityId, transactionId);

    CREATE INDEX sync_operations_attachment_reference_idx ON sync_operations(attachmentReference);

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
        createdAt DATETIME,
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
