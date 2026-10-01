import Foundation
import GRDB

enum BackgroundJobsMigration {
    static func migrate(in db: Database) throws {
        let triggers = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND sql LIKE '%jobs_search_index%'")
        let indexes = try String.fetchAll(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'jobs_search_index' AND sql IS NOT NULL"
        )
        let definition = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'jobs_search_index'")!
        for trigger in triggers {
            let name: String = trigger["name"]
            try db.execute(sql: "DROP TRIGGER \"\(name)\"")
        }
        try db.execute(sql: definition.replacingOccurrences(of: "jobs_search_index", with: "jobs_background")
            .replacingOccurrences(of: "'fts', 'vector'", with: "'fts', 'vector', 'archive'"))
        try db.execute(sql: "INSERT INTO jobs_background SELECT * FROM jobs_search_index; DROP TABLE jobs_search_index;")
        for statement in indexes + triggers.map({ $0["sql"] as String }) {
            try db.execute(sql: statement.replacingOccurrences(of: "jobs_search_index", with: "jobs_background"))
        }
        // The archive manifest remains canonical; this table only schedules preparation/cleanup.
        let enqueue = """
        INSERT INTO jobs_background(indexKind, targetKind, targetKey, availableAt, updatedAt)
        VALUES('archive', 'recordingArchive', new.sessionId, COALESCE(new.retryAt, unixepoch('subsec')), unixepoch('subsec'))
        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET generation = generation + 1,
            status = 'pending', attempts = 0, availableAt = excluded.availableAt, updatedAt = excluded.updatedAt,
            claimedAt = NULL, leaseExpiresAt = NULL;
        """
        try db.execute(sql: """
        CREATE TRIGGER background_archive_insert AFTER INSERT ON recording_archives WHEN new.connectionId IS NOT NULL BEGIN
            \(enqueue)
        END;
        CREATE TRIGGER background_archive_update AFTER UPDATE OF state, retryAt, preparedJSON, audioJSON ON recording_archives WHEN new.connectionId IS NOT NULL BEGIN
            \(enqueue)
        END;
        CREATE TRIGGER background_archive_delete AFTER DELETE ON recording_archives BEGIN
            DELETE FROM jobs_background WHERE indexKind = 'archive' AND targetKey = old.sessionId;
        END;
        INSERT INTO jobs_background(indexKind, targetKind, targetKey, availableAt, updatedAt)
        SELECT 'archive', 'recordingArchive', sessionId, COALESCE(retryAt, unixepoch('subsec')), unixepoch('subsec')
        FROM recording_archives WHERE connectionId IS NOT NULL;
        """)
    }
}
