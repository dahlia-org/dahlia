import DahliaRuntimeSupport
import Foundation
import GRDB

/// Released BLOBs remain recoverable until the file provider verifies their originals.
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
        try db.execute(sql: "DROP TABLE screenshots")
        try db.execute(sql: imageViewSQL)
        if try db.tableExists("search_index_jobs") { try db.execute(sql: searchTriggersSQL) }
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
