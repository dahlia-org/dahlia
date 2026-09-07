import Foundation
import GRDB

enum TextContentMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists("transcript_segments"), try db.tableExists("summaries") else { return }
        // Preserve every original value, FK, index and trigger while relaxing only body nullability.
        let objects = try Row.fetchAll(
            db,
            sql: "SELECT type, name, sql FROM sqlite_master WHERE type IN ('trigger', 'view') AND sql IS NOT NULL ORDER BY rowid"
        )
        for object in objects.reversed() {
            try db.execute(sql: "DROP \(object["type"] as String) \(quoted(object["name"]))")
        }
        try makeNullable("text", table: "transcript_segments", in: db)
        try makeNullable("document", table: "summaries", in: db)
        for object in objects {
            try db.execute(sql: object["sql"])
        }
        try db.execute(sql: """
        CREATE TABLE sync_content_state (
            vaultId BLOB NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            entity TEXT NOT NULL CHECK(entity IN ('summary', 'transcript', 'file')),
            entityId BLOB NOT NULL,
            residentRevision INTEGER,
            complete INTEGER NOT NULL DEFAULT 0,
            present INTEGER NOT NULL DEFAULT 1,
            contentCount INTEGER,
            verifiedHash TEXT,
            byteCount INTEGER NOT NULL DEFAULT 0,
            lastAccessedAt DATETIME,
            fetchError TEXT,
            PRIMARY KEY(vaultId, entity, entityId)
        );
        CREATE TRIGGER sync_content_role_change AFTER UPDATE OF syncRole ON vaults
        WHEN NEW.syncRole IS NOT OLD.syncRole BEGIN
            UPDATE vaults SET syncMutationGeneration = syncMutationGeneration + 1 WHERE id = NEW.id;
        END;
        CREATE TRIGGER sync_content_association_change AFTER UPDATE OF accountConnectionId, syncConfirmedConnectionId, syncRole ON vaults BEGIN
            UPDATE sync_content_state SET fetchError = NULL WHERE vaultId = NEW.id;
        END;
        CREATE INDEX sync_content_lru ON sync_content_state(lastAccessedAt) WHERE complete = 1;
        CREATE TRIGGER sync_content_meeting_delete AFTER DELETE ON meetings BEGIN
            DELETE FROM sync_content_state WHERE entity IN ('summary', 'transcript') AND entityId = OLD.id;
        END;
        CREATE TRIGGER sync_content_file_delete AFTER DELETE ON files BEGIN
            DELETE FROM sync_content_state WHERE entity = 'file' AND entityId = OLD.id;
        END;
        CREATE TRIGGER sync_content_summary_update AFTER UPDATE OF document ON summaries
        WHEN NEW.document IS NOT OLD.document BEGIN
            UPDATE sync_content_state SET verifiedHash = NULL,
                byteCount = byteCount + coalesce(length(CAST(NEW.document AS BLOB)), 0) - coalesce(length(CAST(OLD.document AS BLOB)), 0)
            WHERE entity = 'summary' AND entityId = NEW.meetingId;
        END;
        CREATE TRIGGER sync_content_summary_insert AFTER INSERT ON summaries BEGIN
            UPDATE sync_content_state SET verifiedHash = NULL, present = 1,
                byteCount = coalesce(length(CAST(NEW.document AS BLOB)), 0)
            WHERE entity = 'summary' AND entityId = NEW.meetingId;
        END;
        CREATE TRIGGER sync_content_summary_delete AFTER DELETE ON summaries BEGIN
            UPDATE sync_content_state SET verifiedHash = NULL, byteCount = 0, present = 0, complete = 1
            WHERE entity = 'summary' AND entityId = OLD.meetingId;
        END;
        CREATE TRIGGER sync_content_transcript_update AFTER UPDATE OF text ON transcript_segments
        WHEN NEW.text IS NOT OLD.text BEGIN
            UPDATE sync_content_state SET verifiedHash = NULL,
                byteCount = byteCount + coalesce(length(CAST(NEW.text AS BLOB)), 0) - coalesce(length(CAST(OLD.text AS BLOB)), 0)
            WHERE entity = 'transcript' AND entityId = NEW.meetingId;
        END;
        CREATE TRIGGER sync_content_transcript_insert AFTER INSERT ON transcript_segments BEGIN
            UPDATE sync_content_state SET verifiedHash = NULL,
                byteCount = byteCount + coalesce(length(CAST(NEW.text AS BLOB)), 0)
            WHERE entity = 'transcript' AND entityId = NEW.meetingId;
        END;
        CREATE TRIGGER sync_content_transcript_delete AFTER DELETE ON transcript_segments BEGIN
            UPDATE sync_content_state SET verifiedHash = NULL,
                byteCount = byteCount - coalesce(length(CAST(OLD.text AS BLOB)), 0)
            WHERE entity = 'transcript' AND entityId = OLD.meetingId;
        END;
        CREATE TRIGGER sync_content_file_update AFTER UPDATE OF metadata ON files
        WHEN json_extract(NEW.metadata, '$.ocr_text') IS NOT json_extract(OLD.metadata, '$.ocr_text')
          OR json_extract(NEW.metadata, '$.caption') IS NOT json_extract(OLD.metadata, '$.caption') BEGIN
            UPDATE sync_content_state SET verifiedHash = NULL,
                byteCount = coalesce(length(CAST(json_extract(NEW.metadata, '$.ocr_text') AS BLOB)), 0)
                  + coalesce(length(CAST(json_extract(NEW.metadata, '$.caption') AS BLOB)), 0)
            WHERE entity = 'file' AND entityId = NEW.id;
        END;
        INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete)
        SELECT m.vaultId, 'transcript', m.id, s.confirmedRevision, 1 FROM meetings m
        JOIN vaults v ON v.id = m.vaultId
        LEFT JOIN sync_entity_state s ON s.vaultId = m.vaultId AND s.entity = 'transcript' AND s.entityId = m.id
        WHERE v.accountConnectionId IS NOT NULL;
        INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete)
        SELECT m.vaultId, 'summary', m.id, s.confirmedRevision, 1 FROM summaries b JOIN meetings m ON m.id = b.meetingId
        JOIN vaults v ON v.id = m.vaultId
        LEFT JOIN sync_entity_state s ON s.vaultId = m.vaultId AND s.entity = 'summary' AND s.entityId = m.id
        WHERE v.accountConnectionId IS NOT NULL;
        INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete)
        SELECT f.vaultId, 'file', f.id, s.confirmedRevision, 1 FROM files f JOIN vaults v ON v.id = f.vaultId
        LEFT JOIN sync_entity_state s ON s.vaultId = f.vaultId AND s.entity = 'file' AND s.entityId = f.id
        WHERE v.accountConnectionId IS NOT NULL;
        UPDATE sync_content_state SET byteCount = CASE entity
            WHEN 'summary' THEN coalesce((SELECT length(CAST(document AS BLOB)) FROM summaries WHERE meetingId = entityId), 0)
            WHEN 'transcript' THEN coalesce((SELECT sum(length(CAST(text AS BLOB))) FROM transcript_segments WHERE meetingId = entityId), 0)
            WHEN 'file' THEN coalesce((SELECT coalesce(length(CAST(json_extract(metadata, '$.ocr_text') AS BLOB)), 0)
              + coalesce(length(CAST(json_extract(metadata, '$.caption') AS BLOB)), 0) FROM files WHERE id = entityId), 0)
        END;
        """)
    }

    private static func makeNullable(_ column: String, table: String, in db: Database) throws {
        guard let original = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", arguments: [table])
        else { return }
        let expression = try NSRegularExpression(pattern: "(?i)(\"?\(column)\"?\\s+TEXT)\\s+NOT\\s+NULL")
        let relaxed = expression.stringByReplacingMatches(in: original, range: NSRange(original.startIndex..., in: original), withTemplate: "$1")
        guard relaxed != original else { return }
        let indexes = try String.fetchAll(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL",
            arguments: [table]
        )
        let temporary = table + "_v46"
        guard let range = relaxed.range(of: table) else { throw DatabaseError(message: "missing table definition") }
        var create = relaxed
        create.replaceSubrange(range, with: temporary)
        try db.execute(sql: create)
        try db.execute(sql: "INSERT INTO \(quoted(temporary)) SELECT * FROM \(quoted(table))")
        try db.execute(sql: "DROP TABLE \(quoted(table))")
        try db.execute(sql: "ALTER TABLE \(quoted(temporary)) RENAME TO \(quoted(table))")
        for index in indexes {
            try db.execute(sql: index)
        }
    }

    private static func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}
