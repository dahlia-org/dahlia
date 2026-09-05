import GRDB

enum RetireVectorSearchMigration {
    static func migrate(in db: Database) throws {
        try db.execute(sql: """
        UPDATE search_index_state SET isEnabled = 0 WHERE indexKind = 'vector';
        DROP TRIGGER IF EXISTS search_queue_vector_document_insert;
        DROP TRIGGER IF EXISTS search_queue_vector_document_update;
        DROP TRIGGER IF EXISTS search_invalidate_vector_while_disabled_insert;
        DROP TRIGGER IF EXISTS search_invalidate_vector_while_disabled_update;
        DROP TRIGGER IF EXISTS search_revision_vector_jobs_insert;
        DROP TRIGGER IF EXISTS search_revision_vector_jobs_generation;
        DROP TRIGGER IF EXISTS search_revision_vector_insert;
        DROP TRIGGER IF EXISTS search_revision_vector_update;
        DROP TRIGGER IF EXISTS search_revision_vector_delete;
        """)
    }
}
