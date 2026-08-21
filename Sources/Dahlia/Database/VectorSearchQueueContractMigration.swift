import GRDB

enum VectorSearchQueueContractMigration {
    static func migrate(in db: Database) throws {
        try db.execute(
            sql: """
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
                    generation = generation + 1, status = 'pending', attempts = 0,
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
                    generation = generation + 1, status = 'pending', attempts = 0,
                    availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = NULL, updatedAt = excluded.updatedAt;
            END;

            CREATE TRIGGER search_invalidate_vector_while_disabled_insert
            AFTER INSERT ON search_documents
            WHEN (SELECT isEnabled FROM search_index_state WHERE indexKind = 'vector') = 0 BEGIN
                UPDATE search_index_state SET phase = 'pending', updatedAt = unixepoch('subsec')
                WHERE indexKind = 'vector';
            END;

            CREATE TRIGGER search_invalidate_vector_while_disabled_update
            AFTER UPDATE OF sourceContentHash ON search_documents
            WHEN old.sourceContentHash IS NOT new.sourceContentHash
             AND (SELECT isEnabled FROM search_index_state WHERE indexKind = 'vector') = 0 BEGIN
                UPDATE search_index_state SET phase = 'pending', updatedAt = unixepoch('subsec')
                WHERE indexKind = 'vector';
            END;
            """
        )
    }
}
