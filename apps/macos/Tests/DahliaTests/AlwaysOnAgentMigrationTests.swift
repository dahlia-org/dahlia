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
            let runID = try #require(UUID(uuidString: "018bcfe5-6800-7000-8000-000000000002"))
            let followUpID = try #require(UUID(uuidString: "018bcfe5-6800-7000-8000-000000000001"))
            let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            try queue.write {
                try $0.execute(sql: """
                INSERT INTO chat_runs(id,threadID,rootRunID,status,input,effort,approvalMethod,createdAt,resultExcerpt)
                VALUES(?,?,?,'completed','','medium','ask',?,'Existing result')
                """, arguments: [runID, thread.id, runID, createdAt])
                // Same timestamp, reverse lexical IDs: the database insertion order still records which followed.
                try $0.execute(sql: """
                INSERT INTO chat_runs(id,threadID,rootRunID,status,input,effort,approvalMethod,createdAt,resultExcerpt)
                VALUES(?,?,?,'queued','Follow up','medium','ask',?,'')
                """, arguments: [followUpID, thread.id, followUpID, createdAt])
            }

            try AppDatabaseManager.migrator.migrate(queue)

            try queue.read { db throws in
                #expect(try DahliaAccountConnectionRecord.fetchOne(db, key: provider.id) == provider)
                #expect(try ChatThreadRecord.fetchOne(db, key: thread.id)?.title == thread.title)
                let run = try #require(try ChatRunRecord.fetchOne(db, key: runID))
                #expect(run.createdAt == createdAt && run.resultExcerpt == "Existing result" && run.rootRunID == runID)
                #expect(run.logicalSequence == 1)
                #expect(try ChatThreadStore.latestRun(threadID: thread.id, in: db)?.id == followUpID)
                #expect(try ChatRunRecord.fetchOne(db, key: followUpID)?.logicalSequence == 2)
                #expect(try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='index' AND name='chat_runs_logical_thread')") == true)
                #expect(try db.tableExists("agent_event_sources"))
                #expect(try db.tableExists("chat_thread_launches"))
                #expect(try db.tableExists("agent_tasks") && db.tableExists("agent_user_inbox"))
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }
#endif
