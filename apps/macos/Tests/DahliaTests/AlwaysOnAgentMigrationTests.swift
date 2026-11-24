#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct AlwaysOnAgentMigrationTests {
        @Test func upgradingProviderAccountsPreservesExistingRows() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v67_providerAccounts")
            let provider = DahliaAccountConnectionRecord(
                DatabricksConnection(id: .v7(), host: "https://dbc-1.cloud.databricks.com", email: "me@example.com"),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try queue.write { try provider.insert($0) }
            let store = ChatThreadStore(dbQueue: queue)
            let thread = ChatThreadRecord(
                id: UUID.v7().uuidString,
                accountID: AppAccount.key,
                title: "Keep this conversation",
                createdAt: .now,
                updatedAt: .now
            )
            try store.createThread(thread)

            try AppDatabaseManager.migrator.migrate(queue)

            try queue.read { db throws in
                #expect(try DahliaAccountConnectionRecord.fetchOne(db, key: provider.id) == provider)
                #expect(try ChatThreadRecord.fetchOne(db, key: thread.id)?.title == thread.title)
                #expect(try db.tableExists("agent_event_sources"))
                #expect(try db.tableExists("agent_worker_deliveries"))
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }
#endif
