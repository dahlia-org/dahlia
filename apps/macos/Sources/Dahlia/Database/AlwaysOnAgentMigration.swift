import Foundation
import GRDB

/// The always-on agent's inbox: the Sources intake reads, the events it records, the Tasks (threads Super Agent
/// launched), and the Items it shows the user. Device-local, like chat runs.
enum AlwaysOnAgentMigration {
    static func migrate(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE chat_thread_launches (
            requesterID TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
            rootRunID BLOB NOT NULL, requestID TEXT NOT NULL,
            threadID TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
            PRIMARY KEY(requesterID, rootRunID, requestID)
        );
        CREATE TABLE agent_always_on_settings (
            accountID TEXT PRIMARY KEY NOT NULL, paused BOOLEAN NOT NULL DEFAULT 0
        );
        CREATE TABLE agent_event_sources (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL, name TEXT NOT NULL, server TEXT NOT NULL,
            connectionID TEXT NOT NULL, instructions TEXT NOT NULL, intervalMinutes INTEGER NOT NULL,
            sieve TEXT NOT NULL CHECK(sieve IN ('explicit','candidate','ignore')),
            allowedSenders TEXT NOT NULL DEFAULT '[]', cursor TEXT, enabled BOOLEAN NOT NULL DEFAULT 1, revision INTEGER NOT NULL DEFAULT 1,
            gapDetectedAt DATETIME, lastIntakeAt DATETIME, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
        );
        CREATE INDEX agent_event_sources_account ON agent_event_sources(accountID, createdAt);
        CREATE TABLE agent_tasks (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL, title TEXT NOT NULL, instructions TEXT NOT NULL,
            threadID TEXT REFERENCES chat_threads(id) ON DELETE SET NULL,
            status TEXT NOT NULL CHECK(status IN ('active','done','dismissed')),
            createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
        );
        CREATE INDEX agent_tasks_account ON agent_tasks(accountID, status, updatedAt);
        CREATE UNIQUE INDEX agent_tasks_thread ON agent_tasks(threadID) WHERE threadID IS NOT NULL;
        CREATE TABLE agent_event_inbox (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('external','answer')),
            sourceID TEXT REFERENCES agent_event_sources(id) ON DELETE CASCADE, externalID TEXT, topicKey TEXT,
            sender TEXT, subject TEXT, excerpt TEXT NOT NULL DEFAULT '', url TEXT, ref TEXT, occurredAt DATETIME,
            taskID TEXT REFERENCES agent_tasks(id) ON DELETE SET NULL, payload TEXT NOT NULL DEFAULT '{}',
            status TEXT NOT NULL CHECK(status IN ('ignored','unassigned','processed')),
            createdAt DATETIME NOT NULL
        );
        CREATE UNIQUE INDEX agent_event_inbox_external ON agent_event_inbox(accountID, sourceID, externalID) WHERE externalID IS NOT NULL;
        CREATE INDEX agent_event_inbox_status ON agent_event_inbox(accountID, status, createdAt, id);
        CREATE TABLE agent_user_inbox (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('question','report','suggestion')),
            status TEXT NOT NULL CHECK(status IN ('open','done','dismissed')),
            taskID TEXT REFERENCES agent_tasks(id) ON DELETE CASCADE,
            title TEXT NOT NULL, body TEXT NOT NULL DEFAULT '', options TEXT NOT NULL DEFAULT '[]', recommended INTEGER,
            answer TEXT, revision INTEGER NOT NULL DEFAULT 1,
            createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
        );
        CREATE INDEX agent_user_inbox_status ON agent_user_inbox(accountID, status, createdAt);
        """)
    }
}
