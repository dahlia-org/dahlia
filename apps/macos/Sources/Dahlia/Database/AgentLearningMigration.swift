import Foundation
import GRDB

enum AgentLearningMigration {
    static func migrate(in db: Database) throws {
        try db.execute(sql: """
        ALTER TABLE chat_runs ADD COLUMN origin TEXT NOT NULL DEFAULT 'user';
        ALTER TABLE chat_runs ADD COLUMN profile TEXT NOT NULL DEFAULT 'interactive';
        UPDATE chat_runs SET origin = 'thread' WHERE rootRunID <> id;
        ALTER TABLE chat_items ADD COLUMN runID BLOB;
        ALTER TABLE chat_threads ADD COLUMN memoryTurns INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE chat_threads ADD COLUMN skillIterations INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE chat_threads ADD COLUMN lastSeenSeq INTEGER NOT NULL DEFAULT -1;
        ALTER TABLE chat_threads ADD COLUMN scheduleID TEXT;
        CREATE TABLE agent_memories (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL, target TEXT NOT NULL CHECK(target IN ('user','memory')),
            content TEXT NOT NULL, position INTEGER NOT NULL, createdBy TEXT NOT NULL, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
        );
        CREATE INDEX agent_memories_account ON agent_memories(accountID, target, createdAt, id);
        CREATE TABLE agent_learning_changes (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL, kind TEXT NOT NULL,
            target TEXT NOT NULL, before TEXT, after TEXT, status TEXT NOT NULL,
            source TEXT NOT NULL, threadID TEXT, reviewID TEXT, createdAt DATETIME NOT NULL
        );
        CREATE INDEX agent_learning_changes_account ON agent_learning_changes(accountID, createdAt);
        CREATE TABLE agent_skill_states (
            accountID TEXT NOT NULL, name TEXT NOT NULL, createdBy TEXT NOT NULL, locked BOOLEAN NOT NULL DEFAULT 0,
            PRIMARY KEY(accountID,name)
        );
        CREATE TABLE chat_schedules (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL, threadID TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
            name TEXT NOT NULL, schedule TEXT NOT NULL, prompt TEXT NOT NULL, skills TEXT NOT NULL,
            allowedTools TEXT NOT NULL, revision INTEGER NOT NULL, enabled BOOLEAN NOT NULL, notify BOOLEAN NOT NULL DEFAULT 1,
            nextFireAt DATETIME, createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL
        );
        CREATE TABLE chat_schedule_fires (
            scheduleID TEXT NOT NULL REFERENCES chat_schedules(id) ON DELETE CASCADE,
            fireKey TEXT NOT NULL, revision INTEGER NOT NULL, runID TEXT NOT NULL UNIQUE,
            status TEXT NOT NULL, resultKind TEXT, resultSeq INTEGER, createdAt DATETIME NOT NULL,
            PRIMARY KEY(scheduleID,fireKey)
        );
        CREATE INDEX chat_schedule_fires_status ON chat_schedule_fires(scheduleID,status);
        CREATE TRIGGER chat_schedule_run_interrupted AFTER UPDATE OF status ON chat_runs
        WHEN NEW.origin='schedule' AND NEW.status='interrupted' BEGIN
            UPDATE chat_schedule_fires SET status='interrupted' WHERE runID=NEW.id AND status='queued';
        END;
        CREATE TABLE agent_reviews (
            id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL, threadID TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
            kind TEXT NOT NULL, snapshot TEXT NOT NULL, model TEXT, effort TEXT NOT NULL,
            status TEXT NOT NULL, notified BOOLEAN NOT NULL DEFAULT 0, createdAt DATETIME NOT NULL
        );
        CREATE TRIGGER agent_reviews_delete_job AFTER DELETE ON agent_reviews BEGIN
            DELETE FROM jobs_background WHERE indexKind='review' AND targetKey=OLD.id;
        END;
        """)
        // The existing workers explicitly claim their own kinds. Reviews use a separate single-worker lane.
        let definition = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type='table' AND name='jobs_background'")!
        let triggers = try Row.fetchAll(db, sql: "SELECT name,sql FROM sqlite_master WHERE type='trigger' AND sql LIKE '%jobs_background%'")
        let indexes = try String.fetchAll(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type='index' AND tbl_name='jobs_background' AND sql IS NOT NULL"
        )
        for trigger in triggers {
            let name: String = trigger["name"]
            try db.execute(sql: "DROP TRIGGER \"\(name)\"")
        }
        try db.execute(sql: definition.replacingOccurrences(of: "jobs_background", with: "jobs_background_learning")
            .replacingOccurrences(of: "'archive'", with: "'archive', 'review'"))
        try db
            .execute(
                sql: "INSERT INTO jobs_background_learning SELECT * FROM jobs_background; DROP TABLE jobs_background; ALTER TABLE jobs_background_learning RENAME TO jobs_background;"
            )
        for sql in indexes + triggers.map({ $0["sql"] as String }) {
            try db.execute(sql: sql)
        }
    }
}
