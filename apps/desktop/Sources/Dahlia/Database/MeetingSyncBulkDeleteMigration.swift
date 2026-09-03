import GRDB

enum MeetingSyncBulkDeleteMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists(VaultRecord.databaseTableName) else { return }
        try db.alter(table: VaultRecord.databaseTableName) { table in
            table.add(column: "syncBulkDeleteApproved", .boolean).notNull().defaults(to: false)
        }
    }
}
