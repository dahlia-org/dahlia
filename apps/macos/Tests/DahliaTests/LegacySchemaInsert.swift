#if canImport(Testing)
    import GRDB
    @testable import Dahlia

    extension EncodableRecord where Self: TableRecord {
        /// Inserts into an older schema in a migration test, leaving out columns that a later migration adds.
        func insertIntoLegacySchema(_ db: Database) throws {
            let table = Self.databaseTableName
            let existing = try Set(db.columns(in: table).map(\.name))
            let values = try databaseDictionary.filter { existing.contains($0.key) }
            let names = Array(values.keys)
            try db.execute(
                sql: """
                INSERT INTO \(table) (\(names.map { "\"\($0)\"" }.joined(separator: ", ")))
                VALUES (\(Array(repeating: "?", count: names.count).joined(separator: ", ")))
                """,
                arguments: StatementArguments(names.map { values[$0]! })
            )
        }
    }
#endif
