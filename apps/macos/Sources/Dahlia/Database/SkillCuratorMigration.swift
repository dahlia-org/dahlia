import Foundation
import GRDB

/// Hermes Curator usage records on `agent_skill_states`, and the history of unattended system runs.
enum SkillCuratorMigration {
    static func migrate(in db: Database) throws {
        let existing = try Set(db.columns(in: "agent_skill_states").map(\.name))
        let columns: [(String, String)] = [
            ("useCount", "INTEGER NOT NULL DEFAULT 0"), ("viewCount", "INTEGER NOT NULL DEFAULT 0"),
            ("patchCount", "INTEGER NOT NULL DEFAULT 0"), ("lastUsedAt", "DATETIME"), ("lastViewedAt", "DATETIME"),
            ("lastPatchedAt", "DATETIME"), ("createdAt", "DATETIME"), ("state", "TEXT NOT NULL DEFAULT 'active'"),
            ("pinned", "BOOLEAN NOT NULL DEFAULT 0"), ("archivedAt", "DATETIME"),
        ]
        for (name, definition) in columns where !existing.contains(name) {
            try db.execute(sql: "ALTER TABLE agent_skill_states ADD COLUMN \(name) \(definition)")
        }
        // Skills from before usage tracking are not handed to the Curator; it manages only skills created after this update.
        try db.execute(sql: """
        UPDATE agent_skill_states SET createdBy='user';
        CREATE TABLE IF NOT EXISTS agent_system_runs (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL, task TEXT NOT NULL, status TEXT NOT NULL,
            summary TEXT NOT NULL DEFAULT '', report TEXT NOT NULL DEFAULT '', startedAt DATETIME NOT NULL, finishedAt DATETIME
        );
        CREATE INDEX IF NOT EXISTS agent_system_runs_listing ON agent_system_runs(accountID, startedAt DESC, id DESC);
        CREATE INDEX IF NOT EXISTS agent_system_runs_task ON agent_system_runs(accountID, task, startedAt DESC);
        """)
    }
}
