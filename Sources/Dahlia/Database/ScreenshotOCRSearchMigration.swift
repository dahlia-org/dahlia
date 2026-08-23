import Foundation
import GRDB

enum ScreenshotOCRSearchMigration {
    static func migrate(in db: Database) throws {
        let previousSecureDelete = try Int.fetchOne(db, sql: "PRAGMA secure_delete") ?? 0
        try db.execute(sql: "PRAGMA secure_delete = ON")
        defer { try? db.execute(sql: "PRAGMA secure_delete = \(previousSecureDelete)") }

        let hasScreenshots = try db.tableExists("screenshots")
        if hasScreenshots, try !db.columns(in: "screenshots").contains(where: { $0.name == "ocrText" }) {
            try db.alter(table: "screenshots") { $0.add(column: "ocrText", .text) }
        }
        if hasScreenshots, try !db.columns(in: "screenshots").contains(where: { $0.name == "caption" }) {
            try db.alter(table: "screenshots") { $0.add(column: "caption", .text) }
        }
        if hasScreenshots {
            try db.execute(sql: "UPDATE screenshots SET ocrText = NULL, caption = NULL")
        }

        try db.execute(sql: backupSQL)
        try db.execute(sql: teardownSQL)
        try db.execute(sql: schemaSQL)
        try db.execute(sql: restoreSQL)
        try db.execute(sql: vectorDocumentTriggerSQL)
        try db.execute(
            sql: "INSERT INTO search_documents_fts(search_documents_fts, rank) VALUES('secure-delete', 1)"
        )
        try db.execute(
            sql: """
            DELETE FROM search_index_jobs WHERE indexKind = 'fts';

            UPDATE search_index_state
            SET indexGeneration = indexGeneration + 1,
                indexRevision = indexRevision + 1,
                phase = 'pending', totalCount = 0, completedCount = 0,
                lastErrorCode = NULL, lastIntegrityCheckAt = NULL, updatedAt = ?
            WHERE indexKind = 'fts';
            """,
            arguments: [Date()]
        )
        if hasScreenshots {
            try db.execute(sql: screenshotTriggerSQL)
            try db.execute(
                sql: """
                INSERT INTO search_index_jobs(
                    indexKind, targetKind, targetKey, priority, availableAt, updatedAt
                )
                SELECT 'fts', 'screenshotAnalysis', id, 20, unixepoch('subsec'), unixepoch('subsec')
                FROM screenshots
                """
            )
        }
    }

    private static let backupSQL = """
    CREATE TEMP TABLE search_documents_v38_backup AS
    SELECT id, kind, sourceId, vaultId, meetingId, projectId,
           sourceContentHash, indexGeneration, updatedAt
    FROM search_documents;

    CREATE TEMP TABLE search_documents_vec_v38_backup AS
    SELECT documentId, embedding, sourceContentHash, indexGeneration, updatedAt
    FROM search_documents_vec;
    """

    private static let teardownSQL = """
    DROP TRIGGER IF EXISTS search_queue_vector_document_insert;
    DROP TRIGGER IF EXISTS search_queue_vector_document_update;
    DROP TRIGGER IF EXISTS search_invalidate_vector_while_disabled_insert;
    DROP TRIGGER IF EXISTS search_invalidate_vector_while_disabled_update;
    DROP TRIGGER IF EXISTS search_revision_vector_insert;
    DROP TRIGGER IF EXISTS search_revision_vector_update;
    DROP TRIGGER IF EXISTS search_revision_vector_delete;
    DROP TRIGGER IF EXISTS search_revision_documents_insert;
    DROP TRIGGER IF EXISTS search_revision_documents_update;
    DROP TRIGGER IF EXISTS search_revision_documents_delete;
    DROP TRIGGER IF EXISTS search_queue_screenshots_insert;
    DROP TRIGGER IF EXISTS search_queue_screenshots_delete;
    DROP TABLE search_documents_vec;
    DROP TABLE search_documents_fts_vocab;
    DROP TABLE search_documents_fts;
    DROP TABLE search_documents;
    """

    private static let schemaSQL = """
    CREATE TABLE search_documents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL CHECK(kind IN ('meeting', 'project', 'screenshot')),
        sourceId BLOB NOT NULL,
        vaultId BLOB NOT NULL,
        meetingId BLOB,
        projectId BLOB,
        sourceContentHash TEXT NOT NULL,
        indexGeneration INTEGER NOT NULL,
        updatedAt DATETIME NOT NULL,
        UNIQUE(kind, sourceId)
    );
    CREATE INDEX search_documents_meeting
        ON search_documents(meetingId, kind, indexGeneration);
    CREATE INDEX search_documents_project
        ON search_documents(projectId, kind, indexGeneration);

    CREATE VIRTUAL TABLE search_documents_fts USING fts5(
        title,
        description,
        summary,
        calendar,
        tags,
        projectPath,
        ocr,
        caption,
        content='',
        contentless_delete=1,
        detail=full,
        prefix='2 3',
        tokenize='dahlia_lindera_ipadic_v1'
    );
    CREATE VIRTUAL TABLE search_documents_fts_vocab USING fts5vocab(search_documents_fts, row);

    CREATE TABLE search_documents_vec (
        documentId INTEGER PRIMARY KEY
            REFERENCES search_documents(id) ON DELETE CASCADE,
        embedding BLOB NOT NULL CHECK(length(embedding) = 1024),
        sourceContentHash TEXT NOT NULL,
        indexGeneration INTEGER NOT NULL,
        updatedAt DATETIME NOT NULL
    );

    CREATE TRIGGER search_revision_documents_insert AFTER INSERT ON search_documents BEGIN
        UPDATE search_index_state
        SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
        WHERE indexKind = 'fts';
    END;
    CREATE TRIGGER search_revision_documents_update AFTER UPDATE ON search_documents BEGIN
        UPDATE search_index_state
        SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
        WHERE indexKind = 'fts';
    END;
    CREATE TRIGGER search_revision_documents_delete AFTER DELETE ON search_documents BEGIN
        UPDATE search_index_state
        SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
        WHERE indexKind = 'fts';
    END;

    CREATE TRIGGER search_revision_vector_insert AFTER INSERT ON search_documents_vec BEGIN
        UPDATE search_index_state SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
        WHERE indexKind = 'vector';
    END;
    CREATE TRIGGER search_revision_vector_update AFTER UPDATE ON search_documents_vec BEGIN
        UPDATE search_index_state SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
        WHERE indexKind = 'vector';
    END;
    CREATE TRIGGER search_revision_vector_delete AFTER DELETE ON search_documents_vec BEGIN
        UPDATE search_index_state SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
        WHERE indexKind = 'vector';
    END;
    """

    private static let restoreSQL = """
    INSERT INTO search_documents(
        id, kind, sourceId, vaultId, meetingId, projectId,
        sourceContentHash, indexGeneration, updatedAt
    )
    SELECT id, kind, sourceId, vaultId, meetingId, projectId,
           sourceContentHash, indexGeneration, updatedAt
    FROM search_documents_v38_backup;

    INSERT INTO search_documents_vec(
        documentId, embedding, sourceContentHash, indexGeneration, updatedAt
    )
    SELECT documentId, embedding, sourceContentHash, indexGeneration, updatedAt
    FROM search_documents_vec_v38_backup;

    DROP TABLE search_documents_vec_v38_backup;
    DROP TABLE search_documents_v38_backup;
    """

    private static let vectorDocumentTriggerSQL = """
    CREATE TRIGGER search_queue_vector_document_insert
    AFTER INSERT ON search_documents
    WHEN new.kind != 'screenshot'
     AND (SELECT isEnabled FROM search_index_state WHERE indexKind = 'vector') = 1 BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        VALUES('vector', 'document', new.id, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', attempts = 0,
            availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_queue_vector_document_update
    AFTER UPDATE OF sourceContentHash ON search_documents
    WHEN new.kind != 'screenshot'
     AND old.sourceContentHash IS NOT new.sourceContentHash
     AND (SELECT isEnabled FROM search_index_state WHERE indexKind = 'vector') = 1 BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
        VALUES('vector', 'document', new.id, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, status = 'pending', attempts = 0,
            availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_invalidate_vector_while_disabled_insert
    AFTER INSERT ON search_documents
    WHEN new.kind != 'screenshot'
     AND (SELECT isEnabled FROM search_index_state WHERE indexKind = 'vector') = 0 BEGIN
        UPDATE search_index_state SET phase = 'pending', updatedAt = unixepoch('subsec')
        WHERE indexKind = 'vector';
    END;
    CREATE TRIGGER search_invalidate_vector_while_disabled_update
    AFTER UPDATE OF sourceContentHash ON search_documents
    WHEN new.kind != 'screenshot'
     AND old.sourceContentHash IS NOT new.sourceContentHash
     AND (SELECT isEnabled FROM search_index_state WHERE indexKind = 'vector') = 0 BEGIN
        UPDATE search_index_state SET phase = 'pending', updatedAt = unixepoch('subsec')
        WHERE indexKind = 'vector';
    END;
    """

    private static let screenshotTriggerSQL = """
    CREATE TRIGGER search_queue_screenshots_insert AFTER INSERT ON screenshots BEGIN
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, priority, availableAt, updatedAt)
        VALUES('fts', 'screenshotAnalysis', new.id, 20, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, priority = 20, status = 'pending', attempts = 0,
            availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    CREATE TRIGGER search_queue_screenshots_delete BEFORE DELETE ON screenshots BEGIN
        DELETE FROM search_index_jobs
        WHERE indexKind = 'fts' AND targetKind = 'screenshotAnalysis' AND targetKey = old.id;
        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, priority, availableAt, updatedAt)
        VALUES('fts', 'screenshotCleanup', old.id, 100, unixepoch('subsec'), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
            generation = generation + 1, priority = 100, status = 'pending', attempts = 0,
            availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
            lastErrorCode = NULL, updatedAt = excluded.updatedAt;
    END;
    """
}
