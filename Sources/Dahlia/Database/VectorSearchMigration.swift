import Foundation
import GRDB

enum VectorSearchMigration {
    static func migrate(in db: Database) throws {
        try db.execute(
            sql: """
            ALTER TABLE search_index_state
                ADD COLUMN isEnabled INTEGER NOT NULL DEFAULT 1 CHECK(isEnabled IN (0, 1));

            CREATE TABLE search_documents_vec (
                documentId INTEGER PRIMARY KEY
                    REFERENCES search_documents(id) ON DELETE CASCADE,
                embedding BLOB NOT NULL CHECK(length(embedding) = 1024),
                sourceContentHash TEXT NOT NULL,
                indexGeneration INTEGER NOT NULL,
                updatedAt DATETIME NOT NULL
            );

            INSERT INTO search_index_state(
                indexKind, analyzerVersion, analyzerConfigurationHash, indexGeneration,
                indexRevision, phase, isEnabled, updatedAt
            ) VALUES('vector', ?, ?, 1, 0, 'pending', 0, ?);

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

            CREATE TRIGGER search_revision_vector_jobs_insert
            AFTER INSERT ON search_index_jobs WHEN new.indexKind = 'vector' BEGIN
                UPDATE search_index_state
                SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
                WHERE indexKind = 'vector';
            END;
            CREATE TRIGGER search_revision_vector_jobs_generation
            AFTER UPDATE OF generation ON search_index_jobs WHEN new.indexKind = 'vector' BEGIN
                UPDATE search_index_state
                SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
                WHERE indexKind = 'vector';
            END;
            CREATE TRIGGER search_revision_vector_insert
            AFTER INSERT ON search_documents_vec BEGIN
                UPDATE search_index_state
                SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
                WHERE indexKind = 'vector';
            END;
            CREATE TRIGGER search_revision_vector_update
            AFTER UPDATE ON search_documents_vec BEGIN
                UPDATE search_index_state
                SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
                WHERE indexKind = 'vector';
            END;
            CREATE TRIGGER search_revision_vector_delete
            AFTER DELETE ON search_documents_vec BEGIN
                UPDATE search_index_state
                SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec')
                WHERE indexKind = 'vector';
            END;

            """,
            arguments: [
                EmbeddingGemmaDescriptor.modelIdentifier,
                EmbeddingGemmaDescriptor.configurationHash,
                Date(),
            ]
        )
    }
}
