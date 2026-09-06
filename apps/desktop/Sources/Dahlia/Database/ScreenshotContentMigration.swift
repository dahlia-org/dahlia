import DahliaRuntimeSupport
import Foundation
import GRDB

/// v45 is unreleased. Released BLOBs remain recoverable until the file provider verifies their originals.
enum ScreenshotContentMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists("screenshots"), try db.tableExists("meetings") else { return }
        try db.execute(sql: schemaSQL)
        let rows = try Row.fetchCursor(db, sql: """
        SELECT s.*, m.vaultId FROM screenshots s JOIN meetings m ON m.id = s.meetingId
        """)
        while let row = try rows.next() {
            let bytes: Data = row["imageData"]
            let id: UUID = row["id"]
            let capturedAt: Date = row["capturedAt"]
            let mimeType: String = row["mimeType"]
            try FileRecord(
                id: id,
                vaultId: row["vaultId"],
                size: Int64(bytes.count),
                contentType: mimeType,
                checksum: "SHA-256:" + ScreenshotRemoteReference.digest(bytes),
                name: "capture",
                metadata: FileMetadata(source: .screenshot, ocrText: row["ocrText"], caption: row["caption"]),
                createdAt: capturedAt,
                updatedAt: capturedAt
            ).insert(db)
            try MeetingFileRecord(
                id: id,
                meetingId: row["meetingId"],
                fileId: id,
                capturedAt: capturedAt,
                sessionId: row["sessionId"],
                createdAt: capturedAt
            ).insert(db)
            try db.execute(sql: "INSERT INTO file_migration_content(fileId, imageData) VALUES (?, ?)", arguments: [id, bytes])
        }
        if try db.tableExists("sync_operations") { try migrateOperations(in: db) }
        try db.execute(sql: "DROP TABLE screenshots")
        try db.execute(sql: imageViewSQL)
        if try db.tableExists("search_index_jobs") { try db.execute(sql: searchTriggersSQL) }
        if try db.tableExists("sync_entity_state") {
            try db.execute(sql: "DELETE FROM sync_entity_state WHERE entity = 'screenshot'")
            try db.execute(sql: "UPDATE vaults SET syncPullCursor = NULL WHERE accountConnectionId IS NOT NULL")
        }
    }

    private static func migrateOperations(in db: Database) throws {
        // Materialize old attachment guards before replacing their source table.
        try db.execute(sql: """
        UPDATE sync_operations SET attachmentBytes = (
            SELECT imageData FROM screenshots WHERE screenshots.id = sync_operations.entityId
        ) WHERE entity = 'screenshot' AND attachmentMimeType IS NOT NULL AND attachmentBytes IS NULL;
        DROP TRIGGER IF EXISTS sync_screenshot_attachment_before_update;
        DROP TRIGGER IF EXISTS sync_screenshot_attachment_before_delete;
        """)
        guard let originalSQL = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'sync_operations'")
        else { return }
        let replacement = originalSQL.replacingOccurrences(of: "sync_operations", with: "sync_operations_v45")
            .replacingOccurrences(of: "'transcript', 'screenshot'", with: "'transcript', 'file', 'meeting_file'")
            .replacingOccurrences(of: "entity = 'screenshot'", with: "entity = 'file'")
            .replacingOccurrences(of: "attachmentBytes BLOB,", with: "attachmentBytes BLOB, attachmentReference TEXT,")
        try db.execute(sql: replacement)
        try db.execute(sql: """
        INSERT INTO sync_operations_v45 SELECT *, NULL FROM sync_operations WHERE entity != 'screenshot';
        """)
        let operations = try Row.fetchAll(db, sql: """
        SELECT o.*, t.vaultId, t.createdAt, t.sequence FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
        WHERE o.entity = 'screenshot' ORDER BY t.sequence, o.position
        """)
        var changedTransactions: Set<UUID> = []
        for row in operations {
            let transactionId: UUID = row["transactionId"]
            let id: UUID = row["entityId"]
            let oldOperationId: UUID = row["id"]
            let action: String = row["action"]
            changedTransactions.insert(transactionId)
            let position: Int = row["position"]
            let payload = try (row["payloadJSON"] as String?).flatMap {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            if action == "delete" {
                try db.execute(sql: """
                INSERT INTO sync_operations_v45(transactionId, position, id, entity, action, entityId, baseRevision, payloadJSON)
                VALUES (?, ?, ?, 'meeting_file', 'delete', ?, ?, '{}')
                """, arguments: [transactionId, position, oldOperationId, id, row["baseRevision"] as Int?])
                continue
            }
            var file = try FileRecord.fetchOne(db, key: id)
            // A later deletion supersedes an attachment-free OCR update whose original no longer exists.
            if file == nil, row["attachmentMimeType"] as String? == nil,
               try Bool.fetchOne(db, sql: """
               SELECT EXISTS(
                   SELECT 1 FROM sync_operations d JOIN sync_transactions t ON t.id = d.transactionId
                   WHERE t.vaultId = ? AND d.action = 'delete'
                     AND (t.sequence > ? OR (t.sequence = ? AND d.position > ?))
                     AND ((d.entity = 'screenshot' AND d.entityId = ?) OR (d.entity = 'meeting' AND d.entityId = ?))
               )
               """, arguments: [
                   row["vaultId"] as UUID, row["sequence"] as Int64, row["sequence"] as Int64, position,
                   id, (payload?["meetingId"] as? String).flatMap(UUID.init(uuidString:)),
               ]) == true { continue }
            if file == nil, let bytes: Data = row["attachmentBytes"], let mime: String = row["attachmentMimeType"] {
                let date: Date = row["createdAt"]
                file = FileRecord(
                    id: id,
                    vaultId: row["vaultId"],
                    size: Int64(bytes.count),
                    contentType: mime,
                    checksum: "SHA-256:" + ScreenshotRemoteReference.digest(bytes),
                    name: "capture",
                    metadata: FileMetadata(source: .screenshot),
                    createdAt: date,
                    updatedAt: date
                )
                try file?.insert(db)
                try db.execute(sql: "INSERT INTO file_migration_content(fileId, imageData) VALUES (?, ?)", arguments: [id, bytes])
            }
            guard let file else { throw ScreenshotContentError.unavailable }
            var metadata = file.metadata
            metadata.ocrText = payload?["ocrText"] as? String
            metadata.caption = payload?["caption"] as? String
            let filePayload = try SyncJSON.encoder.encode(FileOperationPayload(name: file.name, checksum: file.checksum, metadata: metadata))
            try db.execute(sql: """
            INSERT INTO sync_operations_v45(transactionId, position, id, entity, action, entityId, payloadJSON,
                                           attachmentMimeType, attachmentSHA256, attachmentBytes)
            VALUES (?, ?, ?, 'file', 'upsert', ?, ?, ?, ?, ?)
            """, arguments: [
                transactionId,
                position,
                oldOperationId,
                id,
                String(decoding: filePayload, as: UTF8.self),
                file.contentType,
                file.contentHash,
                row["attachmentBytes"] as Data?,
            ])
            if let link = try MeetingFileRecord.fetchOne(db, key: id) {
                let last = try Int
                    .fetchOne(db, sql: "SELECT max(position) FROM sync_operations WHERE transactionId = ?", arguments: [transactionId]) ?? 0
                let associationPayload = try SyncInitialSnapshotBuilder.meetingFileOperation(link).payloadJSON!
                try db.execute(sql: """
                INSERT INTO sync_operations_v45(transactionId, position, id, entity, action, entityId, payloadJSON)
                VALUES (?, ?, ?, 'meeting_file', 'upsert', ?, ?)
                """, arguments: [transactionId, last + position + 1, UUID.v7(), id, String(decoding: associationPayload, as: UTF8.self)])
            }
        }
        try db.execute(sql: """
        DROP TABLE sync_operations;
        ALTER TABLE sync_operations_v45 RENAME TO sync_operations;
        CREATE INDEX sync_operations_entity_idx ON sync_operations(entity, entityId, transactionId);
        CREATE INDEX sync_operations_attachment_reference_idx ON sync_operations(attachmentReference);
        """)
        for oldId in changedTransactions {
            if try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE transactionId = ?", arguments: [oldId]) == 0 {
                try db.execute(sql: "DELETE FROM sync_transactions WHERE id = ?", arguments: [oldId])
                continue
            }
            let newId = UUID.v7()
            try db.execute(sql: "UPDATE sync_operations SET transactionId = ? WHERE transactionId = ?", arguments: [newId, oldId])
            try db.execute(sql: """
            UPDATE sync_transactions SET id = ?, attempts = 0, availableAt = ?, leaseExpiresAt = NULL,
                blockedReason = NULL, serverResponseJSON = NULL WHERE id = ?
            """, arguments: [newId, Date(), oldId])
        }
    }

    private static let schemaSQL = """
    CREATE TABLE files (
        id BLOB PRIMARY KEY, vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
        uri TEXT, offset INTEGER NOT NULL DEFAULT 0 CHECK(offset = 0), size INTEGER NOT NULL CHECK(size >= 0),
        content_type TEXT NOT NULL, checksum TEXT NOT NULL, name TEXT NOT NULL, metadata TEXT NOT NULL CHECK(json_valid(metadata)),
        createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, localReference TEXT, remoteReference TEXT
    );
    CREATE INDEX files_vault_id ON files(vaultId, id);
    CREATE TABLE meeting_files (
        id BLOB PRIMARY KEY, meetingId BLOB NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        fileId BLOB NOT NULL REFERENCES files(id), capturedAt DATETIME, sessionId BLOB,
        createdAt DATETIME NOT NULL, UNIQUE(meetingId, fileId)
    );
    CREATE INDEX meeting_files_meeting_id ON meeting_files(meetingId, id);
    CREATE INDEX meeting_files_file_id ON meeting_files(fileId);
    CREATE TABLE file_migration_content (
        fileId BLOB PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE, imageData BLOB NOT NULL
    );
    CREATE TRIGGER meeting_file_same_vault_insert BEFORE INSERT ON meeting_files
    WHEN (SELECT vaultId FROM files WHERE id = new.fileId) IS NOT (SELECT vaultId FROM meetings WHERE id = new.meetingId)
    BEGIN SELECT RAISE(ABORT, 'meeting_file_vault_mismatch'); END;
    CREATE TRIGGER meeting_file_same_vault_update BEFORE UPDATE OF meetingId, fileId ON meeting_files
    WHEN (SELECT vaultId FROM files WHERE id = new.fileId) IS NOT (SELECT vaultId FROM meetings WHERE id = new.meetingId)
    BEGIN SELECT RAISE(ABORT, 'meeting_file_vault_mismatch'); END;
    """

    private static let imageViewSQL = """
    CREATE VIEW meeting_images AS
    SELECT a.id, a.fileId, a.meetingId, a.sessionId, coalesce(a.capturedAt, a.createdAt) AS capturedAt,
        b.imageData, f.content_type AS mimeType, json_extract(f.metadata, '$.ocr_text') AS ocrText,
        json_extract(f.metadata, '$.caption') AS caption, substr(f.checksum, 9) AS contentHash, f.size AS contentLength,
        json_extract(f.metadata, '$.width') AS pixelWidth, json_extract(f.metadata, '$.height') AS pixelHeight,
        f.localReference, f.remoteReference
    FROM meeting_files a JOIN files f ON f.id = a.fileId
    LEFT JOIN file_migration_content b ON b.fileId = f.id
    WHERE json_extract(f.metadata, '$.source') = 'screenshot';
    """

    private static let searchTriggersSQL = """
    CREATE TRIGGER search_queue_meeting_files_insert AFTER INSERT ON meeting_files
    WHEN (SELECT json_extract(metadata, '$.source') FROM files WHERE id = new.fileId) = 'screenshot'
    BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, priority, availableAt, updatedAt)
        SELECT 'fts', CASE WHEN json_extract(metadata, '$.ocr_text') IS NULL THEN 'screenshotAnalysis' ELSE 'screenshot' END,
            new.id, -10, unixepoch('subsec'), unixepoch('subsec') FROM files WHERE id = new.fileId
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET generation = generation + 1, status = 'pending', attempts = 0;
    END;
    CREATE TRIGGER search_queue_files_metadata AFTER UPDATE OF metadata ON files
    WHEN new.metadata IS NOT old.metadata AND json_extract(new.metadata, '$.source') = 'screenshot'
    BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, priority, availableAt, updatedAt)
        SELECT 'fts', 'screenshot', id, 0, unixepoch('subsec'), unixepoch('subsec') FROM meeting_files WHERE fileId = new.id
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET generation = generation + 1, status = 'pending', attempts = 0;
    END;
    CREATE TRIGGER search_queue_meeting_files_delete BEFORE DELETE ON meeting_files BEGIN
        DELETE FROM search_index_jobs WHERE indexKind = 'fts' AND targetKind IN ('screenshotAnalysis', 'screenshot') AND targetKey = old.id;
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, priority, availableAt, updatedAt)
        VALUES('fts', 'screenshotCleanup', old.id, 100, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET generation = generation + 1, status = 'pending', attempts = 0;
    END;
    """
}

struct FileOperationPayload: Codable, Sendable {
    var name: String
    var checksum: String
    var metadata: FileMetadata
}
