import GRDB

/// Extends only the outgoing queue; event history belongs to Server.
enum MeetingEventMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists("vaults") else { return }
        if try !db.columns(in: "vaults").contains(where: { $0.name == "syncMeetingEventsVersion" }) {
            try db.alter(table: "vaults") {
                $0.add(column: "syncMeetingEventsVersion", .integer).notNull().defaults(to: 0)
            }
        }
        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS sync_meeting_events_connection_change
        AFTER UPDATE OF accountConnectionId, syncConfirmedConnectionId ON vaults
        WHEN NEW.accountConnectionId IS NOT OLD.accountConnectionId
            OR NEW.syncConfirmedConnectionId IS NOT OLD.syncConfirmedConnectionId
        BEGIN
            UPDATE vaults SET syncMeetingEventsVersion = 0 WHERE id = NEW.id;
        END;
        """)
        guard let original = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'sync_operations' AND type = 'table'"),
              !original.contains("'meeting_event'") else { return }
        let replacement = original.replacingOccurrences(of: "sync_operations", with: "sync_operations_v47")
            .replacingOccurrences(of: "'meeting_file'", with: "'meeting_file', 'meeting_event'")
        try db.execute(sql: replacement)
        // Preserve child payloads even when DROP TABLE runs with cascading foreign keys enabled.
        try db.execute(sql: """
        CREATE TEMP TABLE meeting_event_patch_backup AS SELECT * FROM sync_transcript_patch_items;
        INSERT INTO sync_operations_v47 SELECT * FROM sync_operations;
        DROP TABLE sync_operations;
        ALTER TABLE sync_operations_v47 RENAME TO sync_operations;
        INSERT OR IGNORE INTO sync_transcript_patch_items SELECT * FROM meeting_event_patch_backup;
        DROP TABLE meeting_event_patch_backup;
        CREATE INDEX sync_operations_entity_idx ON sync_operations(entity, entityId, transactionId);
        CREATE INDEX sync_operations_attachment_reference_idx ON sync_operations(attachmentReference);
        """)
    }
}
