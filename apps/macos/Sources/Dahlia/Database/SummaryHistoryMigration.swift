import GRDB

enum SummaryHistoryMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists("summaries"), try db.tableExists("summary_bodies") else { return }
        try db.execute(sql: """
        CREATE TABLE summary_versions (
            meetingId BLOB NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            version INTEGER NOT NULL,
            title TEXT NOT NULL,
            document TEXT NOT NULL,
            savedAt DATETIME NOT NULL,
            PRIMARY KEY (meetingId, version)
        );
        INSERT INTO summary_versions
        SELECT s.meetingId, 1, s.title, b.document, s.createdAt
        FROM summaries s JOIN summary_bodies b ON b.meetingId = s.meetingId
        JOIN meetings m ON m.id = s.meetingId
        JOIN workspaces w ON w.id = m.workspace_id
        WHERE w.accountConnectionId IS NULL;

        CREATE TRIGGER summary_versions_move_local AFTER UPDATE OF accountConnectionId ON workspaces
        WHEN OLD.accountConnectionId IS NOT NULL AND NEW.accountConnectionId IS NULL BEGIN
            INSERT INTO summary_versions(meetingId, version, title, document, savedAt)
            SELECT s.meetingId,
                COALESCE((SELECT MAX(version) FROM summary_versions WHERE meetingId = s.meetingId), 0) + 1,
                s.title, b.document, strftime('%Y-%m-%d %H:%M:%f', 'now')
            FROM summaries s JOIN summary_bodies b ON b.meetingId = s.meetingId
            JOIN meetings m ON m.id = s.meetingId
            WHERE m.workspace_id = NEW.id AND b.document IS NOT (
                SELECT document FROM summary_versions WHERE meetingId = s.meetingId ORDER BY version DESC LIMIT 1
            );
        END;
        """)
        // Every writer, including the standalone MCP helper, shares the same atomic history boundary.
        for event in ["INSERT", "UPDATE OF document"] {
            let name = event == "INSERT" ? "insert" : "update"
            try db.execute(sql: """
            CREATE TRIGGER summary_versions_\(name) AFTER \(event) ON summary_bodies
            WHEN EXISTS (
                SELECT 1 FROM meetings m JOIN workspaces w ON w.id = m.workspace_id
                WHERE m.id = NEW.meetingId AND w.accountConnectionId IS NULL
            ) AND NEW.document IS NOT (
                SELECT document FROM summary_versions WHERE meetingId = NEW.meetingId ORDER BY version DESC LIMIT 1
            ) BEGIN
                INSERT INTO summary_versions(meetingId, version, title, document, savedAt)
                SELECT NEW.meetingId,
                    COALESCE((SELECT MAX(version) FROM summary_versions WHERE meetingId = NEW.meetingId), 0) + 1,
                    CASE WHEN json_valid(NEW.document) THEN COALESCE(json_extract(NEW.document, '$.title'), s.title) ELSE s.title END,
                    NEW.document, strftime('%Y-%m-%d %H:%M:%f', 'now')
                FROM summaries s WHERE s.meetingId = NEW.meetingId;
            END;
            """)
        }
    }
}
