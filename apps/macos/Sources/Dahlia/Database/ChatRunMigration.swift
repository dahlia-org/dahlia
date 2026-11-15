import GRDB

enum ChatRunMigration {
    static func migrate(in db: Database) throws {
        try db.execute(sql: """
        DROP INDEX chat_items_messages;
        CREATE INDEX chat_items_messages ON chat_items(threadID, seq)
            WHERE (json_extract(data, '$.type') = 'thread_notification' OR (json_extract(data, '$.type') = 'message'
                AND json_extract(data, '$.role') IN ('user', 'assistant')
                AND (COALESCE(json_extract(data, '$.content'), '') <> ''
                    OR COALESCE(json_extract(data, '$.reasoning'), '') <> ''
                    OR json_array_length(data, '$.images') > 0)));
        CREATE TABLE chat_runs (
            id BLOB PRIMARY KEY NOT NULL,
            threadID TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
            requestedByThreadID TEXT REFERENCES chat_threads(id) ON DELETE SET NULL,
            rootRunID BLOB NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('queued', 'running', 'waitingForUser', 'completed', 'interrupted', 'failed')),
            input TEXT NOT NULL,
            model TEXT,
            effort TEXT NOT NULL,
            approvalMethod TEXT NOT NULL,
            clientRequestID TEXT,
            resultDeliveredAt DATETIME,
            createdAt DATETIME NOT NULL,
            resultExcerpt TEXT NOT NULL DEFAULT '',
            suppressAutomaticNotification BOOLEAN NOT NULL DEFAULT 0,
            stoppedByUser BOOLEAN NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX chat_runs_request ON chat_runs(requestedByThreadID, rootRunID, clientRequestID)
            WHERE clientRequestID IS NOT NULL;
        CREATE INDEX chat_runs_thread ON chat_runs(threadID, createdAt, id);
        CREATE INDEX chat_runs_queue ON chat_runs(status, createdAt, id);
        CREATE INDEX chat_runs_budget ON chat_runs(rootRunID);
        CREATE INDEX chat_runs_delivery ON chat_runs(requestedByThreadID, resultDeliveredAt);
        """)
    }
}
