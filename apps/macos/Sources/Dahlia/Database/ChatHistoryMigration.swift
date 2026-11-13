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
        // Rebuild only the registry's CHECK constraint, retaining row IDs and FTS postings.
        let triggers = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'trigger'")
        for trigger in triggers {
            let name: String = trigger["name"]
            try db.execute(sql: "DROP TRIGGER \(name.quotedDatabaseIdentifier)")
        }
        try db.execute(sql: """
        CREATE TABLE search_documents_chat (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL CHECK(kind IN ('meeting', 'project', 'screenshot', 'chat')),
            sourceId BLOB NOT NULL,
            workspace_id BLOB NOT NULL,
            meetingId BLOB,
            projectId BLOB,
            sourceContentHash TEXT NOT NULL,
            indexGeneration INTEGER NOT NULL,
            updatedAt DATETIME NOT NULL,
            chatThreadID TEXT,
            UNIQUE(kind, sourceId)
        );
        INSERT INTO search_documents_chat
            (id, kind, sourceId, workspace_id, meetingId, projectId, sourceContentHash, indexGeneration, updatedAt)
            SELECT * FROM search_documents;
        DROP TABLE search_documents;
        ALTER TABLE search_documents_chat RENAME TO search_documents;
        CREATE INDEX search_documents_meeting ON search_documents(meetingId, kind, indexGeneration);
        CREATE INDEX search_documents_project ON search_documents(projectId, kind, indexGeneration);
        CREATE INDEX search_documents_chat_thread ON search_documents(chatThreadID) WHERE kind = 'chat';
        """)
        for trigger in triggers {
            if let sql: String = trigger["sql"] { try db.execute(sql: sql) }
        }
        // The revision invalidates meeting search cursors. Chat is indexed on every message, so it stays out of it.
        let bump = "UPDATE search_index_state SET indexRevision = indexRevision + 1, updatedAt = unixepoch('subsec') WHERE indexKind = 'fts'"
        for (name, event, condition) in [
            ("jobs_insert", "INSERT ON jobs_background", "new.indexKind = 'fts' AND new.targetKind NOT IN ('chat', 'chatItem')"),
            (
                "jobs_generation",
                "UPDATE OF generation ON jobs_background",
                "new.indexKind = 'fts' AND new.targetKind NOT IN ('chat', 'chatItem')"
            ),
            ("documents_insert", "INSERT ON search_documents", "new.kind <> 'chat'"),
            ("documents_update", "UPDATE ON search_documents", "new.kind <> 'chat'"),
            ("documents_delete", "DELETE ON search_documents", "old.kind <> 'chat'"),
        ] {
            try db.execute(sql: """
            DROP TRIGGER IF EXISTS search_revision_\(name);
            CREATE TRIGGER search_revision_\(name) AFTER \(event) WHEN \(condition) BEGIN \(bump); END;
            """)
        }
        for (name, timing, table, key, kind, condition) in [
            ("thread_insert", "AFTER INSERT", "chat_threads", "unhex(replace(new.id, '-', ''))", "chat", ""),
            (
                "thread_update",
                "AFTER UPDATE OF title, projectID",
                "chat_threads",
                "unhex(replace(new.id, '-', ''))",
                "chat",
                "WHEN new.title IS NOT old.title OR new.projectID IS NOT old.projectID"
            ),
            (
                "item_insert",
                "AFTER INSERT",
                "chat_items",
                "new.id",
                "chatItem",
                "WHEN " + messagePredicate("new.data")
            ),
        ] {
            try db.execute(sql: """
            CREATE TRIGGER chat_search_\(name) \(timing) ON \(table) \(condition) BEGIN
                INSERT INTO jobs_background(indexKind, targetKind, targetKey, availableAt, updatedAt)
                VALUES('fts', '\(kind)', \(key), unixepoch('subsec'), unixepoch('subsec'))
                ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
                    generation = generation + 1, status = 'pending', availableAt = excluded.availableAt,
                    claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = excluded.updatedAt;
            END;
            """)
        }
        try db.execute(sql: """
        CREATE TRIGGER chat_item_search_delete AFTER DELETE ON chat_items BEGIN
            DELETE FROM search_documents_fts WHERE rowid IN
                (SELECT id FROM search_documents WHERE kind = 'chat' AND sourceId = old.id);
            DELETE FROM search_documents WHERE kind = 'chat' AND sourceId = old.id;
            DELETE FROM jobs_background WHERE indexKind = 'fts' AND targetKind = 'chatItem' AND targetKey = old.id;
        END;
        CREATE TRIGGER chat_search_delete AFTER DELETE ON chat_threads BEGIN
            DELETE FROM search_documents_fts WHERE rowid IN
                (SELECT id FROM search_documents WHERE kind = 'chat' AND chatThreadID = old.id);
            DELETE FROM search_documents WHERE kind = 'chat' AND chatThreadID = old.id;
            DELETE FROM jobs_background WHERE indexKind = 'fts' AND targetKind = 'chat' AND targetKey = unhex(replace(old.id, '-', ''));
        END;
        """)
    }
}
