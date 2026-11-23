import Foundation
import GRDB

/// The always-on agent's inbox: sources it reads, the events it records, the tasks and topics it routes them to,
/// the external writes it proposes, the Items it shows the user, and the policies and timers that drive it.
/// Device-local, like chat runs.
enum AlwaysOnAgentMigration {
    static func migrate(in db: Database) throws {
        try db.execute(sql: """
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
            servers TEXT NOT NULL DEFAULT '[]', createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
        );
        CREATE INDEX agent_tasks_account ON agent_tasks(accountID, status, updatedAt);
        CREATE TABLE agent_event_topics (
            accountID TEXT NOT NULL, sourceID TEXT NOT NULL REFERENCES agent_event_sources(id) ON DELETE CASCADE,
            topicKey TEXT NOT NULL, taskID TEXT NOT NULL REFERENCES agent_tasks(id) ON DELETE CASCADE,
            PRIMARY KEY(accountID, sourceID, topicKey)
        );
        CREATE TABLE agent_action_outbox (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL,
            taskID TEXT NOT NULL REFERENCES agent_tasks(id) ON DELETE CASCADE, revision INTEGER NOT NULL,
            server TEXT NOT NULL, tool TEXT NOT NULL, arguments TEXT NOT NULL, principal TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('pending','approved','denied','rejected','executing','succeeded','failed','unknown')),
            approvedRevision INTEGER, policyID TEXT, result TEXT, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
        );
        CREATE INDEX agent_action_outbox_task ON agent_action_outbox(taskID, createdAt);
        CREATE INDEX agent_action_outbox_status ON agent_action_outbox(accountID, status);
        CREATE TABLE agent_event_inbox (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('external','result','decision','split','timer','request','answer')),
            sourceID TEXT REFERENCES agent_event_sources(id) ON DELETE CASCADE, externalID TEXT, topicKey TEXT,
            sender TEXT, subject TEXT, excerpt TEXT NOT NULL DEFAULT '', url TEXT, ref TEXT, occurredAt DATETIME,
            taskID TEXT REFERENCES agent_tasks(id) ON DELETE SET NULL,
            actionID TEXT REFERENCES agent_action_outbox(id) ON DELETE CASCADE, payload TEXT NOT NULL DEFAULT '{}',
            deliveryRunID BLOB REFERENCES chat_runs(id) ON DELETE SET NULL,
            status TEXT NOT NULL CHECK(status IN ('ignored','unassigned','held','assigned','delivered','processed')),
            createdAt DATETIME NOT NULL
        );
        CREATE UNIQUE INDEX agent_event_inbox_external ON agent_event_inbox(accountID, sourceID, externalID) WHERE externalID IS NOT NULL;
        CREATE TABLE agent_worker_deliveries (
            runID BLOB PRIMARY KEY NOT NULL REFERENCES chat_runs(id) ON DELETE CASCADE,
            accountID TEXT NOT NULL, taskID TEXT NOT NULL REFERENCES agent_tasks(id) ON DELETE CASCADE,
            status TEXT NOT NULL CHECK(status IN ('open','reported','retry','cancelled','returned')),
            reportEventID TEXT REFERENCES agent_event_inbox(id) ON DELETE SET NULL
        );
        CREATE INDEX agent_event_inbox_status ON agent_event_inbox(accountID, status, createdAt, id);
        CREATE INDEX agent_event_inbox_task ON agent_event_inbox(taskID, status);
        CREATE TABLE agent_action_policies (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL, server TEXT NOT NULL, tool TEXT NOT NULL,
            conditions TEXT NOT NULL DEFAULT '{}', level INTEGER NOT NULL CHECK(level BETWEEN 1 AND 4),
            enabled BOOLEAN NOT NULL DEFAULT 1, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
        );
        CREATE INDEX agent_action_policies_tool ON agent_action_policies(accountID, server, tool);
        CREATE TABLE agent_timers (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL,
            taskID TEXT REFERENCES agent_tasks(id) ON DELETE CASCADE, note TEXT NOT NULL,
            dueAt DATETIME NOT NULL, firedAt DATETIME, createdAt DATETIME NOT NULL
        );
        CREATE INDEX agent_timers_due ON agent_timers(accountID, firedAt, dueAt);
        CREATE TABLE agent_user_inbox (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('question','approval','report','suggestion')),
            status TEXT NOT NULL CHECK(status IN ('open','done','dismissed')),
            taskID TEXT REFERENCES agent_tasks(id) ON DELETE CASCADE,
            actionID TEXT REFERENCES agent_action_outbox(id) ON DELETE CASCADE,
            title TEXT NOT NULL, body TEXT NOT NULL DEFAULT '', options TEXT NOT NULL DEFAULT '[]', recommended INTEGER,
            answer TEXT, revision INTEGER NOT NULL DEFAULT 1, proposal TEXT,
            createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
        );
        CREATE INDEX agent_user_inbox_status ON agent_user_inbox(accountID, status, createdAt);
        """)
    }
}
