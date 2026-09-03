import GRDB

enum MeetingSyncOriginalTranscriptMigration {
    static func migrate(in db: Database) throws {
        try db.execute(sql: "DROP TRIGGER IF EXISTS meeting_sync_queue_translation")
    }
}
