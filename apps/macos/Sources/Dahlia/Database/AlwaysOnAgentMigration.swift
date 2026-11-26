import Foundation
import GRDB

/// The user's agents and each one's inbox: the Sources intake reads, the events it records, the Tasks (threads the
/// agent launched), and the Items it shows the user. Device-local, like chat runs.
enum AlwaysOnAgentMigration {
    static func migrate(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE chat_thread_launches (
            requesterID TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
            rootRunID BLOB NOT NULL, requestID TEXT NOT NULL,
            threadID TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
            PRIMARY KEY(requesterID, rootRunID, requestID)
        );
        CREATE TABLE agents (
            id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, directory TEXT NOT NULL UNIQUE COLLATE NOCASE,
            avatar TEXT NOT NULL, color TEXT NOT NULL,
            threadID TEXT UNIQUE REFERENCES chat_threads(id) ON DELETE SET NULL,
            intakeModel TEXT, intakeEffort TEXT, unattendedModel TEXT, unattendedEffort TEXT,
            createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
        );
        -- Not a foreign key: a thread stays its agent's, read-only, after the agent is deleted.
        ALTER TABLE chat_threads ADD COLUMN agentID TEXT;
        CREATE INDEX chat_threads_agent ON chat_threads(agentID) WHERE agentID IS NOT NULL;
        CREATE TABLE agent_always_on_settings (
            id INTEGER PRIMARY KEY NOT NULL CHECK(id=1), paused BOOLEAN NOT NULL DEFAULT 0
        );
        CREATE TABLE agent_event_sources (
            id TEXT PRIMARY KEY NOT NULL, agentID TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE, name TEXT NOT NULL, server TEXT NOT NULL,
            connectionID TEXT NOT NULL, instructions TEXT NOT NULL, intervalMinutes INTEGER NOT NULL,
            kind TEXT NOT NULL DEFAULT 'mcp' CHECK(kind IN ('mcp','calendar')),
            allowedSenders TEXT NOT NULL DEFAULT '[]', cursor TEXT, enabled BOOLEAN NOT NULL DEFAULT 1, revision INTEGER NOT NULL DEFAULT 1,
            lastReadCount INTEGER NOT NULL DEFAULT 0, lastRecordedCount INTEGER NOT NULL DEFAULT 0,
            dailyAt TEXT, leadHours DOUBLE,
            lastIntakeAt DATETIME, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
        );
        CREATE INDEX agent_event_sources_created ON agent_event_sources(agentID, createdAt);
        CREATE TABLE agent_tasks (
            id TEXT PRIMARY KEY NOT NULL, agentID TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE, title TEXT NOT NULL, instructions TEXT NOT NULL,
            threadID TEXT UNIQUE REFERENCES chat_threads(id) ON DELETE SET NULL,
            status TEXT NOT NULL CHECK(status IN ('active','done','dismissed')),
            createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
        );
        CREATE INDEX agent_tasks_status ON agent_tasks(agentID, status, updatedAt);
        CREATE TABLE agent_event_inbox (
            id TEXT PRIMARY KEY NOT NULL, agentID TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
            sourceID TEXT REFERENCES agent_event_sources(id) ON DELETE CASCADE,
            key TEXT, topic TEXT, note TEXT NOT NULL, ref TEXT, occurredAt DATETIME NOT NULL,
            taskID TEXT REFERENCES agent_tasks(id) ON DELETE SET NULL, handledAt DATETIME,
            createdAt DATETIME NOT NULL
        );
        CREATE UNIQUE INDEX agent_event_inbox_key ON agent_event_inbox(sourceID, key) WHERE key IS NOT NULL;
        CREATE INDEX agent_event_inbox_open ON agent_event_inbox(agentID, occurredAt, id) WHERE handledAt IS NULL;
        CREATE TABLE agent_user_inbox (
            id TEXT PRIMARY KEY NOT NULL, agentID TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK(kind IN ('question','report','suggestion')),
            status TEXT NOT NULL CHECK(status IN ('open','done','dismissed')),
            taskID TEXT REFERENCES agent_tasks(id) ON DELETE CASCADE,
            title TEXT NOT NULL, body TEXT NOT NULL DEFAULT '', options TEXT NOT NULL DEFAULT '[]', recommended INTEGER,
            answer TEXT, revision INTEGER NOT NULL DEFAULT 1,
            createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
        );
        CREATE INDEX agent_user_inbox_status ON agent_user_inbox(agentID, status, createdAt);
        """)
    }
}
