import GRDB

enum MeetingSyncDeletionConnectionMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists(VaultRecord.databaseTableName) else { return }
        let columns = try db.columns(in: VaultRecord.databaseTableName)
        guard columns.contains(where: { $0.name == "syncDeletionMode" }),
              columns.contains(where: { $0.name == "accountConnectionId" })
        else { return }
        if !columns.contains(where: { $0.name == "syncDeletionConnectionId" }) {
            try db.alter(table: VaultRecord.databaseTableName) { table in
                table.add(column: "syncDeletionConnectionId", .blob)
            }
        }
        try db.execute(sql: """
        UPDATE vaults SET syncDeletionConnectionId = accountConnectionId
        WHERE syncDeletionMode IS NOT NULL
        """)
    }
}
