import Foundation
import GRDB

enum ChatHistoryMigration {
    /// Frozen with v59: a copy of `ChatItemRecord.messagePredicate`, so later edits to it cannot change this migration.
    private static func messagePredicate(_ data: String) -> String {
        """
        json_extract(\(data), '$.type') = 'message'
        AND json_extract(\(data), '$.role') IN ('user', 'assistant')
        AND (COALESCE(json_extract(\(data), '$.content'), '') <> ''
            OR COALESCE(json_extract(\(data), '$.reasoning'), '') <> ''
            OR json_array_length(\(data), '$.images') > 0)
        """
    }

    static func migrate(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE chat_threads (
            id TEXT PRIMARY KEY NOT NULL,
            accountID TEXT NOT NULL,
            workspaceID BLOB NOT NULL,
            projectID BLOB REFERENCES projects(id) ON DELETE SET NULL,
            parentThreadID TEXT REFERENCES chat_threads(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            model TEXT,
            reasoningEffort TEXT,
            status TEXT NOT NULL DEFAULT 'idle'
                CHECK(status IN ('idle', 'running', 'waitingForUser', 'interrupted', 'failed')),
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL
        );
        CREATE INDEX chat_threads_listing ON chat_threads(accountID, workspaceID, updatedAt DESC, id DESC);
        CREATE INDEX chat_threads_parent ON chat_threads(parentThreadID);
        CREATE INDEX chat_threads_project ON chat_threads(projectID);
        CREATE INDEX chat_threads_active ON chat_threads(status) WHERE status IN ('running', 'waitingForUser');
        CREATE TABLE chat_items (
            id BLOB PRIMARY KEY NOT NULL,
            threadID TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            data TEXT NOT NULL CHECK(json_valid(data)),
            createdAt DATETIME NOT NULL,
            UNIQUE(threadID, seq)
        );
        CREATE INDEX chat_items_messages ON chat_items(threadID, seq)
            WHERE \(messagePredicate("data"));
        """)
        // Chat has its own full-text table: sharing one with meetings would shift their BM25 ranks on every message.
        try db.execute(sql: """
        CREATE TABLE search_chat_documents (
            id INTEGER PRIMARY KEY,
            threadID TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
            itemID BLOB UNIQUE REFERENCES chat_items(id) ON DELETE CASCADE
        );
        CREATE UNIQUE INDEX search_chat_documents_title ON search_chat_documents(threadID) WHERE itemID IS NULL;
        CREATE INDEX search_chat_documents_thread ON search_chat_documents(threadID);
        CREATE VIRTUAL TABLE search_chat_documents_fts USING fts5(
            title, description, content='', contentless_delete=1, detail=full, prefix='2 3',
            tokenize='dahlia_lindera_ipadic_v1'
        );
        CREATE VIRTUAL TABLE search_chat_documents_fts_vocab USING fts5vocab(search_chat_documents_fts, row);
        CREATE TRIGGER search_chat_documents_delete AFTER DELETE ON search_chat_documents BEGIN
            DELETE FROM search_chat_documents_fts WHERE rowid = old.id;
        END;
        """)
        // The revision invalidates meeting search cursors. Chat is indexed on every message, so its jobs stay out of it.
        let bump = "UPDATE search_index_state SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec') WHERE indexKind = 'fts'"
        for (name, event) in [("jobs_insert", "INSERT ON jobs_background"), ("jobs_generation", "UPDATE OF generation ON jobs_background")] {
            try db.execute(sql: """
            DROP TRIGGER IF EXISTS search_revision_\(name);
            CREATE TRIGGER search_revision_\(name) AFTER \(event)
            WHEN new.indexKind = 'fts' AND new.targetKind NOT IN ('chat', 'chatItem') BEGIN \(bump); END;
            """)
        }
        for (name, timing, table, key, kind, condition) in [
            ("threads_insert", "AFTER INSERT", "chat_threads", "unhex(replace(new.id, '-', ''))", "chat", ""),
            (
                "threads_update",
                "AFTER UPDATE OF title",
                "chat_threads",
                "unhex(replace(new.id, '-', ''))",
                "chat",
                "WHEN new.title IS NOT old.title"
            ),
            (
                "items_insert",
                "AFTER INSERT",
                "chat_items",
                "new.id",
                "chatItem",
                "WHEN " + messagePredicate("new.data")
            ),
        ] {
            try db.execute(sql: """
            CREATE TRIGGER search_queue_chat_\(name) \(timing) ON \(table) \(condition) BEGIN
                INSERT INTO jobs_background(indexKind, targetKind, targetKey, availableAt, updatedAt)
                VALUES('fts', '\(kind)', \(key), unixepoch('subsec'), unixepoch('subsec'))
                ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
                    generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
                    claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
            END;
            """)
        }
        try db.execute(sql: """
        CREATE TRIGGER search_queue_chat_items_delete AFTER DELETE ON chat_items BEGIN
            DELETE FROM jobs_background WHERE indexKind = 'fts' AND targetKind = 'chatItem' AND targetKey = old.id;
        END;
        CREATE TRIGGER search_queue_chat_threads_delete AFTER DELETE ON chat_threads BEGIN
            DELETE FROM jobs_background WHERE indexKind = 'fts' AND targetKind = 'chat' AND targetKey = unhex(replace(old.id, '-', ''));
        END;
        """)
    }
}
