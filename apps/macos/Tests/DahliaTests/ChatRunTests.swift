#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct ChatRunTests {
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

        @Test func migrationPreservesExistingHistoryAndAddsAnEmptyRunLedger() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v62_accountChatThreads")
            let store = ChatThreadStore(dbQueue: queue)
            let parent = thread()
            let child = thread(parent: parent.id)
            try store.createThread(parent, items: [ChatHistoryCodec.user([.text("Keep me")])])
            try store.createThread(child)
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
