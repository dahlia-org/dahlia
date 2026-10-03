import GRDB

enum DahliaAccountConnectionsMigration {
    static func migrate(in db: Database) throws {
        guard try !db.tableExists(DahliaAccountConnectionRecord.databaseTableName) else { return }
        try db.create(table: DahliaAccountConnectionRecord.databaseTableName) { table in
            table.primaryKey("id", .blob)
            table.column("origin", .text).notNull().unique()
            table.column("clientID", .text).notNull()
            table.column("createdAt", .datetime).notNull()
        }
    }
}
