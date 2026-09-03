import GRDB

enum MeetingSyncScreenshotUploadMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists(MeetingScreenshotRecord.databaseTableName) else { return }
        try db.alter(table: MeetingScreenshotRecord.databaseTableName) { table in
            table.add(column: "syncUploadedConnectionId", .blob)
        }
    }
}
