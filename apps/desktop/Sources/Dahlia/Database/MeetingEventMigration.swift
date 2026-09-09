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
    }
}
