#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct AccountChatMigrationTests {
        @Test
        func removingWorkspaceMembershipPreservesThreadsItemsProjectsAndSearch() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v61_summaryHistory")
            let first = WorkspaceRecord(id: .v7(), name: "First", createdAt: .now, lastOpenedAt: .now)
            let second = WorkspaceRecord(id: .v7(), name: "Second", createdAt: .now, lastOpenedAt: .now)
            let project = ProjectRecord(
                id: .v7(),
                workspaceId: first.id,
                parentProjectId: nil,
                name: "Project",
                createdAt: .now,
                projectType: .undefined
            )
            let parentID = UUID.v7().uuidString.lowercased()
            let childID = UUID.v7().uuidString.lowercased()
            let itemID = UUID.v7()
            try queue.write { db in
                try first.insert(db)
                try second.insert(db)
                try project.insert(db)
                for (id, workspace, parent, projectID) in [
                    (parentID, first.id, nil as String?, project.id as UUID?),
                    (childID, second.id, parentID as String?, nil as UUID?),
                ] {
                    try db.execute(sql: """
                    INSERT INTO chat_threads(id, accountID, workspaceID, projectID, parentThreadID, title, createdAt, updatedAt)
                    VALUES (?, 'local', ?, ?, ?, 'Preserved', ?, ?)
                    """, arguments: [id, workspace, projectID, parent, Date(), Date()])
                }
                try db.execute(sql: """
                INSERT INTO chat_items(id, threadID, seq, data, createdAt) VALUES (?, ?, 0, ?, ?)
                """, arguments: [itemID, parentID, "{\"type\":\"message\",\"role\":\"user\",\"content\":\"Keep me\"}", Date()])
                try db.execute(sql: "INSERT INTO search_chat_documents(threadID) VALUES (?)", arguments: [parentID])
                try db.execute(
                    sql: "INSERT INTO search_chat_documents_fts(rowid, title) VALUES (?, 'preservedterm')",
                    arguments: [db.lastInsertedRowID]
                )
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try AppDatabaseManager.migrator.migrate(queue)
            let store = ChatThreadStore(dbQueue: queue)
            #expect(try Set(store.listThreads(accountID: "local", cursor: nil).threads.map(\.id)) == [parentID, childID])
            #expect(try store.listThreads(accountID: "another", cursor: nil).threads.isEmpty)
            #expect(try store.thread(id: parentID, accountID: "local").projectID == project.id)
            #expect(try store.thread(id: childID, accountID: "local").parentThreadID == parentID)
            #expect(try store.listItems(threadID: parentID).first?.id == itemID)
            try queue.read { db throws in
                #expect(try !db.columns(in: "chat_threads").contains { $0.name == "workspaceID" })
                #expect(try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM search_chat_documents_fts WHERE search_chat_documents_fts MATCH 'preservedterm'"
                ) == 1)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }
#endif
