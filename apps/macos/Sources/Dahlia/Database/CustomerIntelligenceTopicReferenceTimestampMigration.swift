import GRDB

enum CustomerIntelligenceTopicReferenceTimestampMigration {
    static func migrate(in db: Database) throws {
        try db.execute(sql: """
        DROP TRIGGER conversation_topic_references_revision_delete;
        CREATE TRIGGER conversation_topic_references_revision_delete
        AFTER DELETE ON conversation_topic_references
        BEGIN
            UPDATE conversation_topics
            SET revision = revision + 1,
                updatedAt = STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
            WHERE id = OLD.topicId;
        END;
        """)
    }
}
