import GRDB

enum VectorSearchOptInMigration {
    static func migrate(in db: Database) throws {
        try db.execute(
            sql: """
            ALTER TABLE search_index_state
                ADD COLUMN isEnabled INTEGER NOT NULL DEFAULT 1 CHECK(isEnabled IN (0, 1));

            UPDATE search_index_state
            SET isEnabled = 0, phase = 'pending', totalCount = 0, completedCount = 0,
                lastErrorCode = NULL, updatedAt = unixepoch('subsec')
            WHERE indexKind = 'vector';
            DELETE FROM search_index_jobs WHERE indexKind = 'vector';

            DROP TRIGGER search_queue_vector_document_insert;
            CREATE TRIGGER search_queue_vector_document_insert
            AFTER INSERT ON search_documents
            WHEN (SELECT isEnabled FROM search_index_state WHERE indexKind = 'vector') = 1 BEGIN
                INSERT INTO search_index_jobs(
                    indexKind, targetKind, targetKey, availableAt, updatedAt
                ) VALUES(
                    'vector', 'document', new.id, unixepoch('subsec'), unixepoch('subsec')
                )
                ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
                    generation = generation + 1, status = 'pending',
                    availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = NULL, updatedAt = excluded.updatedAt;
            END;

            DROP TRIGGER search_queue_vector_document_update;
            CREATE TRIGGER search_queue_vector_document_update
            AFTER UPDATE OF sourceContentHash ON search_documents
            WHEN old.sourceContentHash IS NOT new.sourceContentHash
             AND (SELECT isEnabled FROM search_index_state WHERE indexKind = 'vector') = 1 BEGIN
                INSERT INTO search_index_jobs(
                    indexKind, targetKind, targetKey, availableAt, updatedAt
                ) VALUES(
                    'vector', 'document', new.id, unixepoch('subsec'), unixepoch('subsec')
                )
                ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
                    generation = generation + 1, status = 'pending',
                    availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = NULL, updatedAt = excluded.updatedAt;
            END;
            """
        )
    }
}
