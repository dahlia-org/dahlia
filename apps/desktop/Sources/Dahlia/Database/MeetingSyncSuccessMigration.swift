import GRDB

enum MeetingSyncSuccessMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists("meetings") else { return }
        try db.create(table: "meeting_sync_success") { table in
            table.column("meetingId", .blob).primaryKey()
                .references("meetings", column: "id", onDelete: .cascade)
            table.column("segmentCount", .integer).notNull()
            table.column("maxSegmentId", .blob)
            table.column("confirmedCount", .integer).notNull()
            table.column("recordingEndedAt", .datetime)
            table.column("batchCompletedAt", .datetime)
        }
    }
}
