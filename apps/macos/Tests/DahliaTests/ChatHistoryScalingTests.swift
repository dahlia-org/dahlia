#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import SQLite3
    import Synchronization
    import Testing
    @testable import Dahlia

    struct ChatHistoryScalingTests {
        @Test
        func deepPagesUseBoundedIndexSeeks() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let queue = database.dbQueue
            let workspaceID = UUID.v7()
            let threadID = "00000000-0000-0000-0000-000000004000"
            try queue.write { db in
                try db.execute(sql: """
                WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<5000)
                INSERT INTO chat_threads(id, accountID, workspaceID, title, createdAt, updatedAt)
                SELECT '00000000-0000-0000-0000-' || printf('%012d', n), 'local', ?, 'History',
                    strftime('%Y-%m-%d %H:%M:%f', '2026-01-01', '+' || n || ' seconds'),
                    strftime('%Y-%m-%d %H:%M:%f', '2026-01-01', '+' || n || ' seconds') FROM numbers
                """, arguments: [workspaceID])
                try db.execute(sql: """
                WITH RECURSIVE numbers(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM numbers WHERE n<9999)
                INSERT INTO chat_items(id, threadID, seq, data, createdAt)
                SELECT randomblob(16), ?, n,
                    CASE WHEN n<1000 THEN json_object('type', 'message', 'role', 'user', 'content', 'message ' || n)
                    WHEN n%2=0 THEN json_object('type', 'message', 'role', 'assistant', 'content', '')
                    ELSE json_object('type', 'tool_result', 'result', 'tool output') END, datetime('now') FROM numbers
                """, arguments: [threadID])
            }
            let store = ChatThreadStore(dbQueue: queue)
            let boundary = try store.thread(id: threadID, accountID: "local")
            let cursor = try JSONEncoder().encode([String(boundary.updatedAt.timeIntervalSince1970), boundary.id]).base64EncodedString()
            let queries = Mutex<[String]>([])
            try queue.writeWithoutTransaction { db in
                db.trace { event in queries.withLock { $0.append(event.expandedDescription) } }
            }
            defer { try? queue.writeWithoutTransaction { $0.trace(nil) } }
            let threads = try store.listThreads(accountID: "local", workspaceID: workspaceID, cursor: cursor)
            #expect(threads.threads.count == 25)
            #expect(threads.threads.first?.id == "00000000-0000-0000-0000-000000003999")
            let messages = try store.messagePage(threadID: threadID)
            #expect(messages.messages.map(\.text) == (960 ..< 1000).map { "message \($0)" })
            try store.beginTurn(threadID: threadID, message: ChatHistoryCodec.user([.text("next")]), model: nil, effort: "low")
            let captured = queries.withLock { $0 }
            try queue.writeWithoutTransaction { $0.trace(nil) }
            #expect(!captured.contains { $0.lowercased().contains("count(*)") })
            let listing = try #require(captured.first { $0.contains("ORDER BY updatedAt DESC") })
            let paging = try #require(captured.first { $0.contains("ORDER BY seq DESC") })
            try queue.read { db in
                for (sql, index, range) in [(listing, "chat_threads_listing", "(updatedAt,id)<"), (paging, "chat_items_messages", "seq<?")] {
                    let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }.joined(separator: " ")
                    #expect(plan.contains(index), Comment(rawValue: plan))
                    #expect(plan.contains(range), Comment(rawValue: plan))
                    let statement = try db.makeStatement(sql: sql)
                    _ = try Row.fetchAll(statement)
                    let steps = sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_VM_STEP, 0)
                    #expect(steps < 2000, "Bounded page should not walk the preceding thousands of rows: \(steps)")
                    print("Chat paging plan: \(plan); VM steps: \(steps)")
                }
                let projectPlan = try Row.fetchAll(
                    db,
                    sql: "EXPLAIN QUERY PLAN SELECT rowid FROM chat_threads WHERE projectID = ?",
                    arguments: [UUID.v7()]
                )
                .map { $0["detail"] as String }.joined(separator: " ")
                #expect(projectPlan.contains("chat_threads_project"))
            }
        }

        @Test
        func rareAndFrequentSearchWordsOnlyProbeCandidateThreads() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let queue = database.dbQueue
            let workspaceID = UUID.v7()
            let expected = "00000000-0000-0000-0000-000000000001"
            try await queue.write { db in
                try db.execute(sql: """
                WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<2000)
                INSERT INTO chat_threads(id, accountID, workspaceID, title, createdAt, updatedAt)
                SELECT '00000000-0000-0000-0000-' || printf('%012d', n), 'local', ?, 'History', datetime('now'), datetime('now') FROM numbers;
                INSERT INTO search_documents(kind, sourceId, workspace_id, sourceContentHash, indexGeneration, updatedAt, chatThreadID)
                SELECT 'chat', unhex(replace(id, '-', '')), workspaceID, 'fixture', 1, updatedAt, id FROM chat_threads;
                INSERT INTO search_documents_fts(rowid, description)
                SELECT id, CASE WHEN chatThreadID = ? THEN 'common rareword' ELSE 'common' END FROM search_documents WHERE kind = 'chat';
                UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'fts';
                """, arguments: [workspaceID, expected])
            }
            let queries = Mutex<[String]>([])
            try await queue.writeWithoutTransaction { db in
                db.trace { event in queries.withLock { $0.append(event.expandedDescription) } }
            }
            defer { try? queue.writeWithoutTransaction { $0.trace(nil) } }
            let page = try await MeetingRepository.searchChatPage(
                workspaceID: workspaceID,
                accountID: "local",
                criteria: .init(text: "common rareword"),
                dbQueue: queue
            )
            #expect(page.threads.map(\.id) == [expected])
            let captured = queries.withLock { $0 }
            try await queue.writeWithoutTransaction { $0.trace(nil) }
            let sql = try #require(captured.first { $0.contains("WITH seeds AS MATERIALIZED") })
            try await queue.read { db in
                let statement = try db.makeStatement(sql: sql)
                _ = try Row.fetchAll(statement)
                let steps = sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_VM_STEP, 0)
                let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql).map { $0["detail"] as String }.joined(separator: "\n")
                #expect(steps < 2000, Comment(rawValue: "VM steps: \(steps)\n" + plan))
                print("Chat rare-token search VM steps over 2000 matching documents: \(steps)")
            }
        }

        @Test
        func messageIndexingIsIncrementalAndSearchGroupsAcrossMessages() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let queue = database.dbQueue
            let store = ChatThreadStore(dbQueue: queue)
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Search", createdAt: .now, lastOpenedAt: .now)
            try await queue.write { try workspace.insert($0) }
            let thread = ChatThreadRecord(
                id: UUID.v7().uuidString.lowercased(),
                accountID: "local",
                workspaceID: workspace.id,
                title: "titletoken",
                createdAt: .now,
                updatedAt: .now
            )
            try store.createThread(thread, items: [ChatHistoryCodec.user([.text("alpha")]), ChatHistoryCodec.user([.text("beta alpha")])])
            await database.searchIndexer.drain()
            let original = try await queue.read { db in
                try Row.fetchAll(db, sql: "SELECT id, updatedAt FROM search_documents WHERE kind = 'chat'")
                    .reduce(into: [Int64: String]()) { $0[$1["id"]] = $1["updatedAt"] }
            }
            #expect(original.count == 3)
            try store.appendItems(threadID: thread.id, items: [ChatHistoryCodec.user([.text("gamma")])])
            await database.searchIndexer.drain()
            try await queue.read { db in
                let rows = try Row.fetchAll(db, sql: "SELECT id, updatedAt FROM search_documents WHERE kind = 'chat'")
                #expect(rows.count == 4)
                for row in rows {
                    let id: Int64 = row["id"]
                    if let oldTime = original[id] { #expect(row["updatedAt"] as String == oldTime) }
                }
            }
            try store.appendItems(threadID: thread.id, items: [.object(["type": .string("tool_result"), "result": .string("secret")])])
            #expect(try await queue
                .read { try Int.fetchOne($0, sql: "SELECT count(*) FROM jobs_background WHERE targetKind IN ('chat', 'chatItem')") } == 0)
            for text in ["alpha", "alpha beta", "titletoken gamma beta", "beta gamma"] {
                let page = try await MeetingRepository.searchChatPage(
                    workspaceID: workspace.id,
                    accountID: "local",
                    criteria: .init(text: text),
                    dbQueue: queue
                )
                #expect(page.threads.map(\.id) == [thread.id])
                #expect(!page.hasMore)
            }
            try store.updateThread(id: thread.id, title: "newtitle")
            await database.searchIndexer.drain()
            #expect(try await MeetingRepository.searchChatPage(
                workspaceID: workspace.id,
                accountID: "local",
                criteria: .init(text: "newtitle beta"),
                dbQueue: queue
            ).threads.count == 1)
            #expect(try await MeetingRepository.searchChatPage(
                workspaceID: workspace.id,
                accountID: "local",
                criteria: .init(text: "titletoken"),
                dbQueue: queue
            ).threads.isEmpty)
            try await database.searchIndexer.requestRebuild()
            #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM search_documents WHERE kind = 'chat'") } == 4)
            let betaItem = try #require(store.listItems(threadID: thread.id).first { $0.seq == 1 })
            _ = try await queue.write { try ChatItemRecord.deleteOne($0, key: betaItem.id) }
            #expect(try await MeetingRepository.searchChatPage(
                workspaceID: workspace.id,
                accountID: "local",
                criteria: .init(text: "beta"),
                dbQueue: queue
            ).threads.isEmpty)
            try store.deleteThread(id: thread.id)
            #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM search_documents WHERE kind = 'chat'") } == 0)
            #expect(try await queue
                .read { try Int.fetchOne($0, sql: "SELECT count(*) FROM jobs_background WHERE targetKind IN ('chat', 'chatItem')") } == 0)
        }
    }
#endif
