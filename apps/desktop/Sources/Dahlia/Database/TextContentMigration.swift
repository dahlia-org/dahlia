import Foundation
import GRDB

enum TextContentMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists("transcript_segments"), try db.tableExists("summaries") else { return }
        // Move bodies without rebuilding their parents: IDs, foreign keys and device-owned columns stay intact.
        let objects = try Row.fetchAll(
            db,
            sql: "SELECT type, name, sql FROM sqlite_master WHERE type IN ('trigger', 'view') AND sql IS NOT NULL ORDER BY rowid"
        )
        for object in objects.reversed() {
            try db.execute(sql: "DROP \(object["type"] as String) \(quoted(object["name"]))")
        }
        try db.execute(sql: """
        CREATE TABLE transcript_segment_bodies (
            segmentId BLOB PRIMARY KEY NOT NULL REFERENCES transcript_segments(id) ON DELETE CASCADE,
            text TEXT NOT NULL
        );
        CREATE TABLE summary_bodies (
            meetingId BLOB PRIMARY KEY NOT NULL REFERENCES summaries(meetingId) ON DELETE CASCADE,
            document TEXT NOT NULL
        );
        CREATE TABLE file_text_bodies (
            fileId BLOB PRIMARY KEY NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            ocrText TEXT,
            caption TEXT
        );
        INSERT INTO transcript_segment_bodies SELECT id, text FROM transcript_segments WHERE isConfirmed = 1;
        INSERT INTO summary_bodies SELECT meetingId, document FROM summaries;
        INSERT INTO file_text_bodies
            SELECT id, json_extract(metadata, '$.ocr_text'), json_extract(metadata, '$.caption') FROM files;
        ALTER TABLE transcript_segments DROP COLUMN text;
        ALTER TABLE summaries DROP COLUMN document;
        UPDATE files SET metadata = json_remove(metadata, '$.ocr_text', '$.caption');
        """)
        for object in objects {
            let name: String = object["name"]
            var sql: String = object["sql"]
            if name == "meeting_images" {
                sql = sql.replacingOccurrences(of: "json_extract(f.metadata, '$.ocr_text')", with: "text.ocrText")
                    .replacingOccurrences(of: "json_extract(f.metadata, '$.caption')", with: "text.caption")
                    .replacingOccurrences(
                        of: "LEFT JOIN file_migration_content",
                        with: "LEFT JOIN file_text_bodies text ON text.fileId = f.id LEFT JOIN file_migration_content"
                    )
            } else if name.hasPrefix("search_queue_summaries_") {
                // Header changes and body changes both invalidate the derived search document.
                try db.execute(sql: sql.replacingOccurrences(of: "UPDATE OF document", with: "UPDATE"))
                sql = sql.replacingOccurrences(of: name, with: name + "_body")
                    .replacingOccurrences(of: "ON summaries", with: "ON summary_bodies")
            } else if name == "search_queue_meeting_files_insert" {
                sql = sql.replacingOccurrences(
                    of: "json_extract(metadata, '$.ocr_text')",
                    with: "(SELECT ocrText FROM file_text_bodies WHERE fileId = files.id)"
                )
            }
            try db.execute(sql: sql)
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
        CREATE TRIGGER sync_content_file_parent_delete AFTER DELETE ON files BEGIN
            DELETE FROM sync_content_state WHERE entity = 'file' AND entityId = OLD.id;
        END;
        CREATE TRIGGER sync_content_summary_header_delete AFTER DELETE ON summaries BEGIN
            UPDATE sync_content_state SET verifiedHash = NULL, byteCount = 0, present = 0, complete = 1
            WHERE entity = 'summary' AND entityId = OLD.meetingId;
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
            WHEN 'summary' THEN coalesce((SELECT length(CAST(document AS BLOB)) FROM summary_bodies WHERE meetingId = entityId), 0)
            WHEN 'transcript' THEN coalesce((SELECT sum(length(CAST(text AS BLOB))) FROM transcript_segments t JOIN transcript_segment_bodies b ON b.segmentId = t.id WHERE t.meetingId = entityId), 0)
            WHEN 'file' THEN coalesce((SELECT coalesce(length(CAST(ocrText AS BLOB)), 0)
              + coalesce(length(CAST(caption AS BLOB)), 0) FROM file_text_bodies WHERE fileId = entityId), 0)
        END;
        """)
        try bodyTriggers(in: db)
    }

    private static func bodyTriggers(in db: Database) throws {
        for (table, entity, key, columns) in [
            ("transcript_segment_bodies", "transcript", "segmentId", ["text"]),
            ("summary_bodies", "summary", "meetingId", ["document"]),
            ("file_text_bodies", "file", "fileId", ["ocrText", "caption"]),
        ] {
            for event in ["INSERT", "UPDATE", "DELETE"] {
                let row = event == "DELETE" ? "OLD" : "NEW"
                let id = entity == "transcript" ? "(SELECT meetingId FROM transcript_segments WHERE id = \(row).segmentId)" : "\(row).\(key)"
                let oldBytes = event == "INSERT" ? "0" : columns.map { "coalesce(length(CAST(OLD.\($0) AS BLOB)), 0)" }.joined(separator: " + ")
                let newBytes = event == "DELETE" ? "0" : columns.map { "coalesce(length(CAST(NEW.\($0) AS BLOB)), 0)" }.joined(separator: " + ")
                let completeness = event == "DELETE" ? ", complete = 0" : ", present = 1"
                try db.execute(sql: """
                CREATE TRIGGER sync_content_\(entity)_\(event.lowercased()) AFTER \(event) ON \(table) BEGIN
                    UPDATE sync_content_state SET verifiedHash = NULL,
                        byteCount = max(0, byteCount + (\(newBytes)) - (\(oldBytes)))\(completeness)
                    WHERE entity = '\(entity)' AND entityId = \(id);
                END;
                """)
                if entity == "file" {
                    try db.execute(sql: """
                    CREATE TRIGGER search_queue_file_text_\(event.lowercased()) AFTER \(event) ON file_text_bodies BEGIN
                        INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, priority, availableAt, updatedAt)
                        SELECT 'fts', 'screenshot', id, 0, unixepoch('subsec'), unixepoch('subsec')
                        FROM meeting_files WHERE fileId = \(row).fileId
                        ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
                            generation = generation + 1, status = 'pending', attempts = 0;
                    END;
                    """)
                }
            }
        }
        // Ordering and membership are part of the transcript fingerprint as well as its text.
        for event in ["INSERT", "UPDATE", "DELETE"] {
            let row = event == "DELETE" ? "OLD" : "NEW"
            let operation = event == "UPDATE" ? "UPDATE OF id, meetingId, startTime, endTime, isConfirmed, audioSource, speakerLabel" : event
            // FK cascades run after the parent disappears, so account for its body while it is still addressable.
            let removedBytes = event == "DELETE"
                ? ", byteCount = max(0, byteCount - coalesce((SELECT length(CAST(text AS BLOB)) FROM transcript_segment_bodies WHERE segmentId = OLD.id), 0))"
                : ""
            try db.execute(sql: """
            CREATE TRIGGER sync_content_transcript_metadata_\(event.lowercased()) BEFORE \(operation) ON transcript_segments BEGIN
                UPDATE sync_content_state SET verifiedHash = NULL\(removedBytes)
                WHERE entity = 'transcript' AND entityId = \(row).meetingId;
            END;
            """)
        }
    }

    private static func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}
