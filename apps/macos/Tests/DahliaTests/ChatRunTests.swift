#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct ChatRunTests {
        @Test func toolCallsRestoreWithIconsSettledStatusInputAndOutput() throws {
            func item(_ id: String, _ data: [String: JSONValue]) -> ChatItem {
                ChatItem(id: id, data: .object(data), createdAt: .now)
            }
            let messages = ChatHistoryCodec.messages([
                item("u", ["type": .string("message"), "role": .string("user"), "content": .string("Inspect")]),
                item("c", [
                    "type": .string("tool_call"),
                    "callID": .string("call"),
                    "name": .string("read"),
                    "arguments": .object(["path": .string("README.md"), "limit": .string("all")]),
                ]),
                item("r", [
                    "type": .string("tool_result"),
                    "callID": .string("call"),
                    "name": .string("read"),
                    "status": .string("succeeded"),
                    "result": .string("file contents"),
                ]),
            ])
            #expect(messages.count == 2)
            let toolMessage = try #require(messages.last)
            #expect(toolMessage.role == .assistant)
            #expect(toolMessage.text.isEmpty)
            #expect(toolMessage.toolActivities == [.init(
                name: "read", status: .succeeded, callID: "call", detail: "README.md",
                input: "{\n  \"limit\" : \"all\",\n  \"path\" : \"README.md\"\n}", output: "file contents"
            )])
            #expect(toolMessage.toolActivities.first?.toolSymbol == "eye")
        }

        @Test(arguments: [false, true])
        func restoredAssistantItemsKeepTheirFinalAnswerAndCompletionTime(includesOpeningRequest: Bool) throws {
            let runID = UUID.v7()
            func item(_ id: String, _ role: String, _ text: String, at seconds: TimeInterval) -> ChatItem {
                ChatItem(
                    id: id, data: .object(["type": .string("message"), "role": .string(role), "content": .string(text)]),
                    createdAt: Date(timeIntervalSince1970: seconds), runID: runID
                )
            }
            var records = includesOpeningRequest ? [item("question", "user", "Inspect", at: 1000)] : []
            records += [item("progress", "assistant", "Investigating", at: 1010), item("answer", "assistant", "Done", at: 1060)]
            let messages = ChatHistoryCodec.messages(records)
            #expect(messages.map(\.id) == records.map(\.id))
            #expect(messages.map(\.timestamp) == records.map(\.createdAt))
            let items = CodexChatConversationItem.build(from: messages)
            let workIndex = includesOpeningRequest ? 1 : 0
            guard case let .work(_, steps, duration) = items[workIndex] else {
                Issue.record("Expected intermediate text in the work log")
                return
            }
            #expect(steps.map(\.text) == ["Investigating"])
            #expect(duration == (includesOpeningRequest ? 60 : nil))
            #expect(try items.last == .message(#require(messages.last)))
            #expect(messages.last?.text == "Done")
        }

        @Test func restoredTextFollowedByToolsDoesNotBecomeAFinalAnswer() {
            let runID = UUID.v7()
            func item(_ id: String, _ data: [String: JSONValue]) -> ChatItem {
                ChatItem(id: id, data: .object(data), createdAt: .now, runID: runID)
            }
            let messages = ChatHistoryCodec.messages([
                item("u", ["type": .string("message"), "role": .string("user"), "content": .string("Inspect")]),
                item("a", ["type": .string("message"), "role": .string("assistant"), "content": .string("Investigating")]),
                item("c", ["type": .string("tool_call"), "callID": .string("call"), "name": .string("read")]),
                item("r", ["type": .string("tool_result"), "callID": .string("call"), "name": .string("read")]),
            ])
            #expect(messages.last?.endsWithToolActivity == true)
            #expect(CodexChatConversationItem.build(from: messages) == messages.map { .message($0) })
        }

        @Test func toolMetadataIsBoundedAndDoesNotAttachToAnEarlierTurn() {
            let detail = CodexChatToolActivity.displayDetail(.object(["command": .string(String(repeating: "x", count: 1000))]))
            #expect(detail?.count == 240)
            var message = CodexChatMessage(role: .assistant, text: "")
            for index in 0 ..< 150 {
                message.recordToolActivity(.init(name: "bash", status: .running, callID: "call-\(index)"))
            }
            #expect(message.toolActivities.count == 100)
            let items = [
                ChatItem(
                    id: "a",
                    data: .object(["type": .string("message"), "role": .string("assistant"), "content": .string("Earlier")]),
                    createdAt: .now
                ),
                ChatItem(
                    id: "u",
                    data: .object(["type": .string("message"), "role": .string("user"), "content": .string("New turn")]),
                    createdAt: .now
                ),
                ChatItem(id: "tool", data: .object(["type": .string("tool_call"), "name": .string("bash")]), createdAt: .now),
            ]
            let restored = ChatHistoryCodec.messages(items)
            #expect(restored.first?.toolActivities.isEmpty == true)
            #expect(restored.last?.toolActivities.first?.name == "bash")
        }

        @Test func toolCallAndResultAcrossPagesMergeAtTheCallPosition() {
            let call = CodexChatMessage(role: .assistant, text: "Inspecting", toolActivities: [
                .init(name: "read", status: .running, callID: "call", detail: "README.md"),
            ])
            let result = CodexChatMessage(role: .assistant, text: "", toolActivities: [
                .init(name: "read", status: .succeeded, callID: "call"),
            ])
            let reply = CodexChatMessage(role: .assistant, text: "Done")
            let merged = CodexChatMessage.prependingHistory([call], to: [result, reply])
            #expect(merged.count == 2)
            #expect(merged.first?.id == call.id)
            #expect(merged.first?.toolActivities == [.init(name: "read", status: .succeeded, callID: "call", detail: "README.md")])
            #expect(merged.last == reply)
        }

        @Test func conversationPagesRestoreToolMetadata() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let target = thread()
            try store.createThread(target)
            try store.appendItems(threadID: target.id, items: [
                .object([
                    "type": .string("tool_call"),
                    "callID": .string("call"),
                    "name": .string("read"),
                    "arguments": .object(["path": .string("README.md")]),
                ]),
                .object(["type": .string("tool_result"), "callID": .string("call"), "name": .string("read"), "status": .string("succeeded")]),
            ])
            let page = try store.messagePage(threadID: target.id)
            #expect(page.messages.first?.toolActivities == [.init(
                name: "read", status: .succeeded, callID: "call", detail: "README.md", input: "{\n  \"path\" : \"README.md\"\n}"
            )])
        }

        @Test func toolPagingDoesNotMergeCallIDsAcrossRuns() {
            let first = CodexChatMessage(role: .assistant, text: "First", toolActivities: [
                .init(name: "read", status: .running, callID: "shared"),
            ], runID: .v7())
            let second = CodexChatMessage(role: .assistant, text: "Second", toolActivities: [
                .init(name: "read", status: .succeeded, callID: "shared"),
            ], runID: .v7())
            #expect(CodexChatMessage.prependingHistory([first], to: [second]) == [first, second])
        }

        @Test func decodedMessagesAndToolsRetainTheirStoredRunIdentity() {
            let runID = UUID.v7()
            let items = [
                ChatItem(id: "user", data: .object([
                    "type": .string("message"), "role": .string("user"), "content": .string("Inspect"),
                ]), createdAt: .now, runID: runID),
                ChatItem(id: "call", data: .object([
                    "type": .string("tool_call"), "name": .string("read"), "callID": .string("call"),
                ]), createdAt: .now, runID: runID),
            ]
            #expect(ChatHistoryCodec.messages(items).allSatisfy { $0.runID == runID })
        }

        @Test func timestampMigrationPreservesExistingRuns() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v64_agentLearning")
            let store = ChatThreadStore(dbQueue: queue)
            let target = thread()
            try store.createThread(target)
            let existing = run(target: target.id)
            try queue.write { db in
                try db.execute(sql: """
                INSERT INTO chat_runs(id, threadID, rootRunID, status, input, effort, approvalMethod, createdAt, resultExcerpt)
                VALUES (?, ?, ?, 'completed', 'Preserved request', 'medium', 'ask', ?, 'Preserved result')
                """, arguments: [existing.id, target.id, existing.rootRunID, existing.createdAt])
            }
            let createdAt = try queue.read { try Date.fetchOne($0, sql: "SELECT createdAt FROM chat_runs WHERE id = ?", arguments: [existing.id]) }
            try AppDatabaseManager.migrator.migrate(queue)
            let restored = try #require(try store.run(id: existing.id))
            #expect(restored.threadID == target.id)
            #expect(restored.status == "completed")
            #expect(restored.input == "Preserved request")
            #expect(restored.resultExcerpt == "Preserved result")
            #expect(restored.createdAt == createdAt)
            #expect(restored.startedAt == nil)
            #expect(restored.completedAt == nil)
            #expect(restored.requestedByRunID == nil)
            try AppDatabaseManager.migrator.migrate(queue)
            #expect(try store.thread(id: target.id, accountID: "local").title == target.title)
        }

        @Test func runTimesStartAtClaimAndStayFixedAfterCompletion() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let target = thread()
            try store.createThread(target)
            let queued = try store.enqueueRun(run(target: target.id))
            #expect(queued.startedAt == nil)
            #expect(try store.claimQueuedRun(queued.id))
            let startedAt = try #require(try store.run(id: queued.id)?.startedAt)
            #expect(try !store.claimQueuedRun(queued.id))
            try store.setRunStatus(queued.id, status: "running")
            #expect(try store.run(id: queued.id)?.startedAt == startedAt)
            #expect(try store.run(id: queued.id)?.completedAt == nil)
            try store.setRunStatus(queued.id, status: "completed")
            let completedAt = try #require(try store.run(id: queued.id)?.completedAt)
            #expect(completedAt >= startedAt)
            try store.setRunStatus(queued.id, status: "completed")
            #expect(try store.run(id: queued.id)?.completedAt == completedAt)
        }

        @Test func resultNotificationKeepsCompletionTimeAndSeparateRunsForOneThread() {
            let content = """
            <thread_results source="dahlia" untrusted="true">
            [{"run_id":"one","thread_id":"child","title":"Child","status":"completed","excerpt":"First result","model":"test-model","started_at":1200,"completed_at":1234.5},
             {"run_id":"two","thread_id":"child","title":"Child","status":"completed","excerpt":"Second result"}]
            </thread_results>
            """
            let message = ChatHistoryCodec.messages([ChatItem(id: "notice", data: .object([
                "type": .string("thread_notification"), "content": .string(content),
            ]), createdAt: Date(timeIntervalSince1970: 9000))]).first
            #expect(message?.threadResults.map(\.id) == ["one", "two"])
            #expect(message?.threadResults.first?.thread.completedAt == Date(timeIntervalSince1970: 1234.5))
            #expect(message?.threadResults.first?.thread.firstMessage == "First result")
            #expect(message?.threadResults.first?.thread.model == "test-model")
            #expect(message?.threadResults.first?.thread.startedAt == Date(timeIntervalSince1970: 1200))
            #expect(message?.threadResults.last?.thread.completedAt == nil)
        }

        private func thread(account: String = "local", parent: String? = nil) -> ChatThreadRecord {
            ChatThreadRecord(
                id: UUID.v7().uuidString.lowercased(),
                accountID: account,
                parentThreadID: parent,
                title: "Thread",
                createdAt: .now,
                updatedAt: .now
            )
        }

        private func run(target: String, requester: String? = nil, root: UUID? = nil, key: String? = nil) -> ChatRunRecord {
            let id = UUID.v7()
            return ChatRunRecord(
                id: id,
                threadID: target,
                requestedByThreadID: requester,
                rootRunID: root ?? id,
                status: "queued",
                input: "Do work",
                effort: "medium",
                approvalMethod: "ask",
                clientRequestID: key,
                createdAt: .now
            )
        }

        @Test func historyKeepsChildrenWithTheirParentAndShowsUnloadedParentsChildren() {
            let parent = CodexChatThreadSummary(id: "parent", title: "Parent", updatedAt: .now)
            let child = CodexChatThreadSummary(id: "child", title: "Child", updatedAt: .now, parentThreadID: parent.id)
            let orphan = CodexChatThreadSummary(id: "orphan", title: "Orphan", updatedAt: .now, parentThreadID: "not-loaded")
            #expect(CodexChatThreadSummary.treeOrder([child, orphan, parent]).map(\.id) == ["orphan", "parent", "child"])
        }

        @Test func sidebarHidesChildrenEvenWhenTheirParentIsNotLoaded() {
            let parent = CodexChatThreadSummary(id: "parent", title: "Parent", updatedAt: .now)
            let child = CodexChatThreadSummary(id: "child", title: "Child", updatedAt: .now, parentThreadID: parent.id)
            let orphan = CodexChatThreadSummary(id: "orphan", title: "Orphan", updatedAt: .now, parentThreadID: "not-loaded")
            #expect(CodexChatThreadSummary.sidebarThreads([child, orphan, parent]).map(\.id) == [parent.id])
            #expect(CodexChatThreadSummary.sidebarThreads([child, orphan]).isEmpty)
        }

        @Test func migrationPreservesExistingHistoryAndAddsAnEmptyRunLedger() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v62_accountChatThreads")
            let store = ChatThreadStore(dbQueue: queue)
            let parent = thread()
            let child = thread(parent: parent.id)
            // Seed the released schema directly; current records include columns added by later migrations.
            try queue.write { db in
                for record in [parent, child] {
                    try db.execute(sql: """
                    INSERT INTO chat_threads(id,accountID,parentThreadID,title,status,createdAt,updatedAt) VALUES(?,?,?,?,?,?,?)
                    """, arguments: [
                        record.id,
                        record.accountID,
                        record.parentThreadID,
                        record.title,
                        record.status,
                        record.createdAt,
                        record.updatedAt,
                    ])
                }
                let data = try String(decoding: JSONEncoder().encode(ChatHistoryCodec.user([.text("Keep me")])), as: UTF8.self)
                try db.execute(
                    sql: "INSERT INTO chat_items(id,threadID,seq,data,createdAt) VALUES(?,?,0,?,?)",
                    arguments: [UUID.v7(), parent.id, data, Date()]
                )
            }
            try AppDatabaseManager.migrator.migrate(queue)
            #expect(try store.thread(id: child.id, accountID: "local").parentThreadID == parent.id)
            #expect(try store.messagePage(threadID: parent.id).messages.map(\.text) == ["Keep me"])
            try queue.read { db throws in
                #expect(try ChatRunRecord.fetchCount(db) == 0)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test func runDedupeIsScopedToRequesterAndDoesNotConsumeBudget() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let parent = thread(), target = thread()
            try store.createThread(parent)
            try store.createThread(target)
            let first = try store.enqueueRun(run(target: target.id, requester: parent.id, key: "retry"), budget: 1)
            let repeated = try store.enqueueRun(run(target: target.id, requester: parent.id, root: first.rootRunID, key: "retry"), budget: 1)
            #expect(first.id == repeated.id)
            #expect(throws: (any Error).self) {
                try store.enqueueRun(run(target: target.id, requester: parent.id, root: first.rootRunID, key: "next"), budget: 1)
            }
        }

        @Test func listingCanFilterQueuedThreads() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let parent = thread(), target = thread()
            try store.createThread(parent)
            try store.createThread(target)
            _ = try store.enqueueRun(run(target: target.id, requester: parent.id, key: "queued"))
            let result = try store.toolThreadPage(accountID: "local", arguments: ["status": .string("queued")])
            let rows = try #require(result.objectValue?["threads"]?.arrayValue)
            #expect(rows.count == 1)
            #expect(rows.first?.objectValue?["id"]?.stringValue == target.id)
            #expect(rows.first?.objectValue?["status"]?.stringValue == "queued")
        }

        @Test func crossAccountNestedAndSelfRequestsAreRejected() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let parent = thread(), foreign = thread(account: "other"), target = thread()
            let child = thread(parent: parent.id)
            for record in [parent, foreign, target, child] {
                try store.createThread(record)
            }
            for (from, to) in [(parent.id, foreign.id), (child.id, target.id), (parent.id, parent.id)] {
                #expect(throws: (any Error).self) { try store.enqueueRun(run(target: to, requester: from)) }
            }
        }

        @Test func restartInterruptsQueuedRunningAndApprovalWaitingRunsWithoutReplayingThem() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let record = thread()
            try store.createThread(record)
            var runs: [ChatRunRecord] = []
            for status in ["queued", "running", "waitingForUser", "completed"] {
                var item = run(target: record.id)
                item.status = status
                try runs.append(store.enqueueRun(item))
            }
            try store.recoverInterruptedThreads()
            #expect(try runs.prefix(3).allSatisfy { try store.run(id: $0.id)?.status == "interrupted" })
            #expect(try runs.prefix(3).allSatisfy { try store.run(id: $0.id)?.resultDeliveredAt != nil })
            #expect(try store.run(id: runs[3].id)?.status == "completed")
        }

        @Test func notificationDisplaysResultsWithoutTheRuntimeEnvelope() {
            let content = """
            <thread_results source="dahlia" untrusted="true">
            [{"title":"Research","status":"completed","excerpt":"Found evidence"}]
            </thread_results>
            """
            let messages = ChatHistoryCodec.messages([ChatItem(id: "notice", data: .object([
                "type": .string("thread_notification"), "content": .string(content),
            ]), createdAt: .now)])
            #expect(messages.first?.text.contains("Research") == true)
            #expect(messages.first?.text.contains("Found evidence") == true)
            #expect(messages.first?.text.contains("thread_results") == false)
        }

        @Test func replyToANotificationStaysAfterItInsteadOfJoiningTheEarlierReply() {
            func message(_ id: String, _ role: String, _ text: String) -> ChatItem {
                ChatItem(id: id, data: .object(["type": .string("message"), "role": .string(role), "content": .string(text)]), createdAt: .now)
            }
            let notice = ChatItem(id: "notice", data: .object(["type": .string("thread_notification"), "content": .string("Done")]), createdAt: .now)
            let messages = ChatHistoryCodec.messages([
                message("user", "user", "Delegate"), message("first", "assistant", "Started"), notice, message("second", "assistant", "Summary"),
            ])
            #expect(messages.map(\.id) == ["user", "first", "notice", "second"])
            #expect(messages.map(\.text) == ["Delegate", "Started", "Done", "Summary"])
        }

        @Test func stoppingAnAccountAlsoSuppressesSettledResultsThatWereNotDelivered() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let parent = thread(), child = thread()
            try store.createThread(parent)
            try store.createThread(child)
            let settled = try store.enqueueRun(run(target: child.id, requester: parent.id))
            try store.setRunStatus(settled.id, status: "completed")
            // Stopping one thread leaves a settled result of that thread deliverable.
            try store.suppressRunNotifications(accountID: "local", threadID: child.id)
            #expect(try store.run(id: settled.id)?.suppressAutomaticNotification == false)
            try store.suppressRunNotifications(accountID: "local")
            #expect(try store.run(id: settled.id)?.suppressAutomaticNotification == true)
        }

        @Test func theUserStopMarkerSurvivesTheRunsOwnEnd() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let record = thread()
            try store.createThread(record)
            let root = try store.enqueueRun(run(target: record.id))
            try store.markStoppedByUser(root.id)
            try store.setRunStatus(root.id, status: "completed")
            #expect(try store.run(id: root.id)?.stoppedByUser == true)
        }

        @Test func aReplyLongerThanOnePageCanBeReadInFull() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let record = thread()
            let reply = String(repeating: "a", count: 8000) + String(repeating: "b", count: 500)
            try store.createThread(record, items: [.object(["type": .string("message"), "role": .string("assistant"), "content": .string(reply)])])
            let first = try store.readForTool(threadID: record.id, arguments: ["max_characters": .number(8000)]).objectValue
            let item = try #require(first?["items"]?.arrayValue?.first?.objectValue)
            #expect(item["truncated"] == .bool(true))
            #expect(first?["complete"] == .bool(false))
            let rest = try store.readForTool(threadID: record.id, arguments: [
                "item_cursor": #require(item["cursor"]), "text_offset": #require(item["next_text_offset"]), "max_characters": .number(8000),
            ]).objectValue?["items"]?.arrayValue?.first?.objectValue
            #expect(rest?["text"]?.stringValue == String(repeating: "b", count: 500))
            #expect(rest?["truncated"] == .bool(false))
        }

        @Test func notificationClaimAndHistoryAreAtomicAndExcludedFromMessageSearchJobs() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let parent = thread(), child = thread()
            try store.createThread(parent)
            try store.createThread(child)
            let childRun = try store.enqueueRun(run(target: child.id, requester: parent.id))
            try store.setRunStatus(childRun.id, status: "completed")
            let notification = run(target: parent.id, root: childRun.rootRunID)
            try store.enqueueNotification(notification, deliveredRuns: [childRun])
            #expect(try store.undeliveredRuns(requesterID: parent.id).isEmpty)
            let messages = try store.messagePage(threadID: parent.id).messages
            #expect(messages.count == 1)
            #expect(messages.first?.role == .notice(.info))
            try store.dbQueue.read { db throws in
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jobs_background WHERE targetKind = 'chatItem'") == 0)
            }
            try store.setRunStatus(childRun.id, status: "waitingForUser")
            try store.setRunStatus(childRun.id, status: "completed")
            #expect(try store.undeliveredRuns(requesterID: parent.id).count == 1)
        }

        @Test func toolReadPagesMessagesAndBoundsContentWithoutReturningReasoningOrArguments() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let record = thread()
            try store.createThread(record)
            try store.appendItems(threadID: record.id, items: [
                .object([
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "content": .string("12345678"),
                    "reasoning": .string("private thinking"),
                ]),
                .object(["type": .string("tool_call"), "name": .string("read"), "arguments": .string("hidden")]),
                ChatHistoryCodec.user([.text("last")]),
            ])
            let first = try store.readForTool(threadID: record.id, arguments: ["limit": .number(1), "max_characters": .number(4)])
            #expect(first.objectValue?["items"]?.arrayValue?.first?.objectValue?["text"] == .string("1234"))
            #expect(first.objectValue?["items"]?.arrayValue?.first?.objectValue?["truncated"] == .bool(true))
            let second = try store.readForTool(threadID: record.id, arguments: ["cursor": first.objectValue?["next_cursor"] ?? .null])
            #expect(second.objectValue?["items"]?.arrayValue?.count == 1)
            #expect(second.objectValue?["items"]?.arrayValue?.first?.objectValue?["text"] == .string("last"))
        }

        @Test func slowSubscriberIsDisconnectedWithoutFinishingOtherSubscribers() async throws {
            var broadcast = ChatTurnBroadcast()
            let (slow, slowReader) = AsyncThrowingStream<CodexChatTurnEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
            let (fast, fastReader) = AsyncThrowingStream<CodexChatTurnEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(10))
            broadcast.readers[UUID.v7()] = slowReader
            broadcast.readers[UUID.v7()] = fastReader
            broadcast.yield(.delta(itemID: "one", text: "a"))
            broadcast.yield(.delta(itemID: "one", text: "b"))
            #expect(broadcast.readers.count == 1)
            #expect(broadcast.text == "ab")
            broadcast.yield(.completed(itemID: "one", text: "ab"))
            broadcast.finish()
            var fastEvents: [CodexChatTurnEvent] = []
            for try await event in fast {
                fastEvents.append(event)
            }
            #expect(fastEvents.count == 3)
            await #expect(throws: ChatTurnBroadcast.ReaderOverflow.self) { for try await _ in slow {} }
        }
    }
#endif
