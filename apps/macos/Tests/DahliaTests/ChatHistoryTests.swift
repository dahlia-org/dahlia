#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct ChatHistoryTests {
        private func thread(workspaceID: UUID = .v7(), accountID: String = "local", parentID: String? = nil) -> ChatThreadRecord {
            ChatThreadRecord(
                id: UUID.v7().uuidString.lowercased(),
                accountID: accountID,
                workspaceID: workspaceID,
                parentThreadID: parentID,
                title: "Conversation",
                model: "test/model",
                reasoningEffort: "medium",
                createdAt: .now,
                updatedAt: .now
            )
        }

        @Test
        func migrationPreservesExistingDataAndIndexRows() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v58_searchDictionaries")
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Preserved", createdAt: .now, lastOpenedAt: .now)
            try queue.write { db in
                try workspace.insert(db)
                try upsertDocument(
                    SearchDocumentProjection(
                        kind: "project",
                        sourceID: workspace.id,
                        workspaceID: workspace.id,
                        meetingID: nil,
                        projectID: nil,
                        fields: SearchDocumentFields(
                            title: "preservedterm",
                            description: "",
                            calendar: "",
                            tags: "",
                            projectPath: ""
                        )
                    ),
                    generation: 1,
                    in: db
                )
            }
            let oldRowID = try queue.read { try Int64.fetchOne($0, sql: "SELECT id FROM search_documents") }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db throws in
                #expect(try WorkspaceRecord.fetchOne(db, key: workspace.id)?.name == "Preserved")
                #expect(try Int64.fetchOne(db, sql: "SELECT id FROM search_documents") == oldRowID)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM search_documents_fts WHERE search_documents_fts MATCH 'preservedterm'") == 1)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test
        func itemsAreOrderedPagedAndChildrenStayInTheirAccount() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let store = ChatThreadStore(dbQueue: database.dbQueue)
            let parent = thread()
            let child = thread(workspaceID: parent.workspaceID, parentID: parent.id)
            try store.createThread(parent)
            try store.createThread(child)
            #expect(throws: (any Error).self) {
                try store.createThread(thread(workspaceID: parent.workspaceID, accountID: "another", parentID: parent.id))
            }
            try store.appendItems(threadID: child.id, items: (0 ..< 105).map { .object(["number": .number(Double($0))]) })
            let first = try store.listItems(threadID: child.id, limit: 1000)
            #expect(first.map(\.seq) == Array(0 ..< 100).map(Int64.init))
            #expect(try store.listItems(threadID: child.id, after: first.last?.seq).map(\.seq) == [100, 101, 102, 103, 104])
            #expect(throws: (any Error).self) { try store.thread(id: parent.id, accountID: "another") }
            #expect(throws: (any Error).self) { try store.thread(id: parent.id, accountID: "local", workspaceID: .v7()) }
            try store.deleteThread(id: parent.id)
            #expect(try store.listItems(threadID: child.id).isEmpty)
            #expect(try database.dbQueue.read { try ChatThreadRecord.fetchCount($0) } == 0)
        }

        @Test
        func indexingChatLeavesTheMeetingSearchRevisionUnchanged() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let store = ChatThreadStore(dbQueue: database.dbQueue)
            await database.searchIndexer.drain()
            func count(_ sql: String) async throws -> Int? {
                try await database.dbQueue.read { try Int.fetchOne($0, sql: sql) }
            }
            let revisionSQL = "SELECT indexRevision FROM search_index_state WHERE indexKind = 'fts'"
            let before = try await count(revisionSQL)
            let meetingDocuments = try await count("SELECT COUNT(*) FROM search_documents")
            let record = thread()
            try store.createThread(record, items: [ChatHistoryCodec.user([.text("hello")])])
            try store.updateThread(id: record.id, title: "Renamed")
            await database.searchIndexer.drain()
            #expect(try await count("SELECT COUNT(*) FROM search_chat_documents") == 2)
            #expect(try await count("SELECT COUNT(*) FROM search_chat_documents_fts WHERE search_chat_documents_fts MATCH 'hello'") == 1)
            // Meeting ranks depend on the whole table's statistics, so chat postings never enter it.
            #expect(try await count("SELECT COUNT(*) FROM search_documents") == meetingDocuments)
            #expect(try await count("SELECT COUNT(*) FROM search_documents_fts_vocab WHERE term = 'hello'") == 0)
            try store.deleteThread(id: record.id)
            #expect(try await count("SELECT COUNT(*) FROM search_chat_documents_fts WHERE search_chat_documents_fts MATCH 'hello'") == 0)
            #expect(try await count(revisionSQL) == before)
        }

        @Test
        func itemStoreUsesOpaqueCursorsAndStoreAssignedIDs() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let store = ChatThreadStore(dbQueue: database.dbQueue)
            let record = thread()
            try store.createThread(record)
            let itemStore: any ChatItemStore = store
            try await itemStore.appendItems(
                threadID: record.id,
                items: [ChatHistoryCodec.user([.text("one")]), ChatHistoryCodec.user([.text("two")])]
            )
            let first = try await itemStore.listItems(threadID: record.id, cursor: nil, limit: 1)
            let second = try await itemStore.listItems(threadID: record.id, cursor: first.nextCursor, limit: 1)
            #expect(first.items.count == 1)
            #expect(second.items.count == 1)
            #expect(first.items.first?.id != second.items.first?.id)
            #expect(ChatHistoryCodec.messages(first.items).first?.text == "one")
            #expect(ChatHistoryCodec.messages(second.items).first?.text == "two")
        }

        @Test
        func deletingAnAccountDeletesOnlyItsThreadsAndSignOutKeepsThem() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let account = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.test", clientID: "test", createdAt: .now)
            try await database.dbQueue.write { try account.insert($0) }
            let store = ChatThreadStore(dbQueue: database.dbQueue)
            let owned = thread(accountID: account.id.uuidString.lowercased())
            let local = thread()
            try store.createThread(owned, items: [ChatHistoryCodec.user([.text("Private")])])
            try store.createThread(local)
            // Databricks sign-out removes only the account row.
            let databricks = DatabricksConnection(id: .v7(), host: "https://example.cloud.databricks.com")
            let signedOut = thread(accountID: databricks.id.uuidString.lowercased())
            try await database.dbQueue.write { db in
                try DahliaAccountConnectionRecord(databricks, createdAt: .now).insert(db)
            }
            try store.createThread(signedOut)
            _ = try await database.dbQueue.write { try DahliaAccountConnectionRecord.deleteOne($0, key: databricks.id) }
            #expect(try store.thread(id: signedOut.id, accountID: signedOut.accountID).id == signedOut.id)

            try await MeetingRepository(dbQueue: database.dbQueue).deleteDahliaAccountConnection(id: account.id)
            #expect(try store.listItems(threadID: owned.id).isEmpty)
            #expect(throws: (any Error).self) { try store.thread(id: owned.id, accountID: owned.accountID) }
            #expect(try store.thread(id: local.id, accountID: "local").id == local.id)
        }

        @Test
        func threadListUsesAStableKeysetAndRecoveryKeepsMessages() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let store = ChatThreadStore(dbQueue: database.dbQueue)
            var one = thread()
            one.status = "running"
            var two = thread(workspaceID: one.workspaceID)
            two.updatedAt = one.updatedAt.addingTimeInterval(-1)
            try store.createThread(one, items: [ChatHistoryCodec.user([.text("kept")])])
            try store.createThread(two)
            let first = try store.listThreads(accountID: "local", workspaceID: one.workspaceID, cursor: nil, limit: 1)
            #expect(first.threads.map(\.id) == [one.id])
            try store.updateThread(id: one.id, title: "New title")
            let second = try store.listThreads(accountID: "local", workspaceID: one.workspaceID, cursor: first.nextCursor, limit: 1)
            #expect(second.threads.map(\.id) == [two.id])
            try store.recoverInterruptedThreads()
            #expect(try store.thread(id: one.id, accountID: "local").status == "interrupted")
            #expect(try ChatHistoryCodec.messages(store.listItems(threadID: one.id)).first?.text == "kept")
        }

        @Test
        func initialMeetingContextUsesTheSharedProjectAndDeletionKeepsHistory() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Work", createdAt: .now, lastOpenedAt: .now)
            let project = ProjectRecord(id: .v7(), workspaceId: workspace.id, path: "Project", createdAt: .now)
            let meeting = MeetingRecord(
                id: .v7(),
                workspaceId: workspace.id,
                projectId: project.id,
                name: "Meeting",
                createdAt: .now,
                updatedAt: .now
            )
            try database.dbQueue.write { db in
                try workspace.insert(db)
                try project.insert(db)
                try meeting.insert(db)
            }
            let store = ChatThreadStore(dbQueue: database.dbQueue)
            let record = thread(workspaceID: workspace.id)
            try store.createThread(record)
            let prompt = CodexChatPromptCodec.encode(text: "hello", context: .meeting(id: meeting.id, name: meeting.name, calendarEvent: nil))
            try store.beginTurn(threadID: record.id, message: ChatHistoryCodec.user([.text(prompt)]), model: nil, effort: "high")
            #expect(try store.thread(id: record.id, accountID: "local").projectID == project.id)
            _ = try database.dbQueue.write { try ProjectRecord.deleteOne($0, key: project.id) }
            #expect(try store.thread(id: record.id, accountID: "local").projectID == nil)
            #expect(try store.listItems(threadID: record.id).count == 1)
        }

        @Test
        func backupContainsNoChatRecordsOrSearchPostings() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Backup", createdAt: .now, lastOpenedAt: .now)
            try await database.dbQueue.write { try workspace.insert($0) }
            let store = ChatThreadStore(dbQueue: database.dbQueue)
            let record = thread(workspaceID: workspace.id)
            try store.createThread(record, items: [ChatHistoryCodec.user([.text("privatechatsecret")])])
            await database.searchIndexer.drain()
            let root = URL.temporaryDirectory.appending(path: "chat-backup-\(UUID.v7())")
            defer { try? FileManager.default.removeItem(at: root) }
            let generation = try await BackupService(dbQueue: database.dbQueue, applicationSupportURL: root)
                .createGeneration(workspaceIds: [workspace.id])
            let queue = try DatabaseQueue(path: extractedBackupDatabase(generation.fileURL).path, configuration: AppDatabaseManager.configuration())
            defer { try? queue.close() }
            try await queue.read { db throws in
                #expect(try ChatThreadRecord.fetchCount(db) == 0)
                #expect(try ChatItemRecord.fetchCount(db) == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM search_chat_documents") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM search_chat_documents_fts WHERE search_chat_documents_fts MATCH 'privatechatsecret'") == 0)
            }
        }

        @Test
        func searchUsesMessageTextAndScopesAndRebuildsChats() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Search", createdAt: .now, lastOpenedAt: .now)
            let otherWorkspace = WorkspaceRecord(id: .v7(), path: nil, name: "Other", createdAt: .now, lastOpenedAt: .now)
            try await database.dbQueue.write { db in try workspace.insert(db)
                try otherWorkspace.insert(db)
            }
            let store = ChatThreadStore(dbQueue: database.dbQueue)
            let one = thread(workspaceID: workspace.id)
            let otherAccount = thread(workspaceID: workspace.id, accountID: UUID.v7().uuidString.lowercased())
            let other = thread(workspaceID: otherWorkspace.id)
            for record in [one, otherAccount, other] {
                try store.createThread(record, items: [
                    ChatHistoryCodec.user([.text("日本語の検索と会議の記録 uniquemessage")]),
                    .object([
                        "type": .string("message"),
                        "role": .string("assistant"),
                        "content": .string("assistantresponse"),
                        "reasoning": .string("hiddenreasoning"),
                    ]),
                    .object(["type": .string("tool_result"), "result": .string("hiddentooloutput")]),
                ])
            }
            await database.searchIndexer.drain()
            let queue = database.dbQueue
            let page = try await MeetingRepository.searchChatPage(
                workspaceID: workspace.id,
                accountID: "local",
                criteria: .init(text: "uniquemessage"),
                dbQueue: queue
            )
            #expect(page.threads.map(\.id) == [one.id])
            let japanese = try await MeetingRepository.searchChatPage(
                workspaceID: workspace.id,
                accountID: "local",
                criteria: .init(text: "日本語"),
                dbQueue: queue
            )
            #expect(japanese.threads.map(\.id) == [one.id])
            for text in ["hiddenreasoning", "hiddentooloutput"] {
                #expect(try await MeetingRepository.searchChatPage(
                    workspaceID: workspace.id,
                    accountID: "local",
                    criteria: .init(text: text),
                    dbQueue: queue
                ).threads.isEmpty)
            }
            try await database.searchIndexer.requestRebuild()
            #expect(try await MeetingRepository.searchChatPage(
                workspaceID: workspace.id,
                accountID: "local",
                criteria: .init(text: "assistantresponse"),
                dbQueue: queue
            ).threads.map(\.id) == [one.id])
            try store.deleteThread(id: one.id)
            #expect(try await MeetingRepository.searchChatPage(
                workspaceID: workspace.id,
                accountID: "local",
                criteria: .init(text: "uniquemessage"),
                dbQueue: queue
            ).threads.isEmpty)
        }

        @Test
        func searchRespectsProjectDescendantsDatesAndTags() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Filters", createdAt: .now, lastOpenedAt: .now)
            let parent = ProjectRecord(id: .v7(), workspaceId: workspace.id, path: "Parent", createdAt: .now)
            let child = ProjectRecord(
                id: .v7(),
                workspaceId: workspace.id,
                parentProjectId: parent.id,
                name: "Child",
                createdAt: .now,
                projectType: nil
            )
            try await database.dbQueue.write { db in
                try workspace.insert(db)
                try parent.insert(db)
                try child.insert(db)
            }
            let store = ChatThreadStore(dbQueue: database.dbQueue)
            var attached = thread(workspaceID: workspace.id)
            attached.projectID = child.id
            let other = thread(workspaceID: workspace.id)
            try store.createThread(attached, items: [ChatHistoryCodec.user([.text("filterword")])])
            try store.createThread(other, items: [ChatHistoryCodec.user([.text("filterword")])])
            await database.searchIndexer.drain()
            let queue = database.dbQueue
            let filtered = try await MeetingRepository.searchChatPage(
                workspaceID: workspace.id,
                accountID: "local",
                criteria: .init(text: "filterword", projectIDs: [parent.id]),
                dbQueue: queue
            )
            #expect(filtered.threads.map(\.id) == [attached.id])
            let tagged = try await MeetingRepository.searchChatPage(
                workspaceID: workspace.id,
                accountID: "local",
                criteria: .init(text: "filterword", tagIDs: [1]),
                dbQueue: queue
            )
            #expect(tagged.threads.isEmpty)
            let future = try await MeetingRepository.searchChatPage(
                workspaceID: workspace.id,
                accountID: "local",
                criteria: .init(text: "filterword", startDate: Date().addingTimeInterval(86400)),
                dbQueue: queue
            )
            #expect(future.threads.isEmpty)
            let first = try await MeetingRepository.searchChatPage(
                workspaceID: workspace.id,
                accountID: "local",
                criteria: .init(text: "filterword"),
                limit: 1,
                dbQueue: queue
            )
            #expect(first.hasMore)
            let second = try await MeetingRepository.searchChatPage(
                workspaceID: workspace.id,
                accountID: "local",
                criteria: .init(text: "filterword"),
                offset: 1,
                limit: 1,
                dbQueue: queue
            )
            #expect(first.threads.first?.id != second.threads.first?.id)
        }

        @Test
        func toolPayloadsAreBoundedValidJSONAndImagesAndContextRoundTrip() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let store = ChatThreadStore(dbQueue: database.dbQueue)
            let record = thread()
            try store.createThread(record)
            let context = CodexChatContext.project(id: .v7(), name: "Project", description: "Description")
            try store.appendItems(threadID: record.id, items: [ChatHistoryCodec.user([
                .text(CodexChatPromptCodec.encode(text: "Hello", context: context)),
                .imageDataURI("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aVVQAAAAASUVORK5CYII="),
            ])])
            let restored = try #require(ChatHistoryCodec.messages(store.listItems(threadID: record.id)).first)
            #expect(restored.text == "Hello")
            #expect(restored.context == context)
            #expect(restored.images.first?
                .dataURI == "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aVVQAAAAASUVORK5CYII=")
            let bounded = try ChatHistoryCodec.bounded(.string(String(repeating: "大", count: 100_000)))
            #expect(bounded.objectValue?["truncated"]?.boolValue == true)
            _ = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(bounded))
        }
    }
#endif
