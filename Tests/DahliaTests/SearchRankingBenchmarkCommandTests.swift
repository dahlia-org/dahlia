import GRDB
@testable import DahliaSearchRankingBenchmark

#if canImport(Testing)
    import Testing

    struct SearchRankingBenchmarkCommandTests {
        @Test
        func requiresReadySearchIndex() throws {
            let database = try DatabaseQueue()
            try database.write { db in
                try db.create(table: "search_index_state") { table in
                    table.column("indexKind", .text).primaryKey()
                    table.column("phase", .text).notNull()
                    table.column("indexRevision", .integer).notNull()
                }
                try db.execute(
                    sql: "INSERT INTO search_index_state VALUES ('fts', 'pending', 7)"
                )
            }

            #expect(throws: BenchmarkError.searchIndexNotReady("pending")) {
                try SearchIndexSnapshot.ready(in: database)
            }

            try database.write { db in
                try db.execute(
                    sql: "UPDATE search_index_state SET phase = 'ready', indexRevision = 8 WHERE indexKind = 'fts'"
                )
            }
            #expect(try SearchIndexSnapshot.ready(in: database) == .init(phase: "ready", revision: 8))
        }
    }
#endif
