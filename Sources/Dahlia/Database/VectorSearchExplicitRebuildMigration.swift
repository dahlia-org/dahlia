import GRDB

enum VectorSearchExplicitRebuildMigration {
    static func migrate(in db: Database) throws {
        try db.execute(
            sql: """
            UPDATE search_index_state
            SET phase = 'pending', updatedAt = unixepoch('subsec')
            WHERE indexKind = 'vector';
            """
        )
    }
}
