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
            let existing = run(target: target.id)
            try queue.write { db in
                // The record has columns later migrations add, so the old schema gets a plain insert.
                try db.execute(
                    sql: "INSERT INTO chat_threads (id, accountID, title, status, createdAt, updatedAt) VALUES (?, ?, ?, 'idle', ?, ?)",
                    arguments: [target.id, target.accountID, target.title, target.createdAt, target.updatedAt]
                )
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
            #expect(queued.startedAt == nil && queued.executionSequence == nil)
            let claimed = try #require(try store.claimQueuedRun(queued))
            let executionSequence = try #require(claimed.executionSequence)
            let startedAt = try #require(try store.run(id: queued.id)?.startedAt)
            #expect(try store.claimQueuedRun(queued) == nil)
            try store.setRunStatus(queued.id, status: "running")
            #expect(try store.run(id: queued.id)?.startedAt == startedAt)
            #expect(try store.run(id: queued.id)?.completedAt == nil)
            try store.setRunStatus(queued.id, status: "completed")
            let completedAt = try #require(try store.run(id: queued.id)?.completedAt)
            #expect(completedAt >= startedAt)
            try store.setRunStatus(queued.id, status: "completed")
            #expect(try store.run(id: queued.id)?.completedAt == completedAt)
            #expect(try store.run(id: queued.id)?.executionSequence == executionSequence)
        }

        @Test(arguments: ["interrupted", "failed"], [false, true])
        func terminalUnstartedRunsKeepTheirAcceptancePosition(terminal: String, queuedReplacement: Bool) throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let parent = thread(), target = thread()
            try store.createThread(parent)
            try store.createThread(target)
            // More acceptances than starts must not put the two positions on incomparable counters.
            for _ in 0 ..< 10 {
                let neverStarted = try store.enqueueRun(run(target: target.id))
                try store.interruptQueuedRun(neverStarted.id)
            }
            let old = try store.enqueueRun(run(target: target.id, requester: parent.id))
            if terminal == "failed" {
                _ = try #require(try store.failQueuedRun(old))
            } else {
                try store.interruptQueuedRun(old.id)
            }
            var replacement = run(target: target.id, requester: parent.id)
            replacement.status = queuedReplacement ? "queued" : "running"
            let accepted = try store.enqueueRun(replacement)
            let started = try #require(try queuedReplacement ? store.claimQueuedRun(accepted) : accepted)
            #expect(try #require(started.executionSequence) > #require(accepted.logicalSequence))
            #expect(try store.latestRun(threadID: target.id)?.id == started.id)
            try store.setRunStatus(started.id, status: "completed")
            #expect(try store.latestRun(threadID: target.id)?.id == started.id)
            #expect(try store.undeliveredRuns(requesterID: parent.id).map(\.id) == [old.id, started.id])
            // The inverse case: a newer request that fails before starting still has a visible result.
            let newest = try store.enqueueRun(run(target: target.id, requester: parent.id))
            _ = try #require(try store.failQueuedRun(newest))
            #expect(try store.latestRun(threadID: target.id)?.id == newest.id)
            #expect(try store.undeliveredRuns(requesterID: parent.id).map(\.id) == [old.id, started.id, newest.id])
        }

        @Test(arguments: ["thread", "requester", "nilRequester"], [false, true])
        func queuedTransitionsRejectPreparationForAnOldRoute(change: String, failing: Bool) throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let target = thread(), replacement = thread(), requester = thread()
            for record in [target, replacement, requester] {
                try store.createThread(record)
            }
            let queued = try store.enqueueRun(run(target: target.id, requester: change == "nilRequester" ? nil : requester.id))
            try store.dbQueue.write { db in
                if change == "thread" {
                    try db.execute(sql: "UPDATE chat_runs SET threadID=? WHERE id=?", arguments: [replacement.id, queued.id])
                } else {
                    try db.execute(sql: "UPDATE chat_runs SET requestedByThreadID=? WHERE id=?", arguments: [replacement.id, queued.id])
                }
            }
            #expect(try store.claimQueuedRun(queued) == nil)
            #expect(try store.failQueuedRun(queued) == nil)
            let current = try #require(try store.run(id: queued.id))
            #expect(current.status == "queued" && current.startedAt == nil && current.completedAt == nil && current.executionSequence == nil)
            let transitioned = try #require(try failing ? store.failQueuedRun(current) : store.claimQueuedRun(current))
            #expect(transitioned.status == (failing ? "failed" : "running"))
            #expect((transitioned.executionSequence == nil) == failing)
            #expect(transitioned.threadID == current.threadID && transitioned.requestedByThreadID == current.requestedByThreadID)
            #expect(try store.claimQueuedRun(current) == nil)
            #expect(try store.failQueuedRun(current) == nil)
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
            let result = try store.toolThreadPage(accountID: "local", arguments: ["statuses": .array([.string("queued")])])
            let rows = try #require(result.objectValue?["threads"]?.arrayValue)
            #expect(rows.count == 1)
            #expect(rows.first?.objectValue?["id"]?.stringValue == target.id)
            #expect(rows.first?.objectValue?["status"]?.stringValue == "queued")
            // Subagent (child) threads are left out unless asked for.
            try store.setParent(target.id, parentID: parent.id, accountID: "local")
            let topLevel = try store.toolThreadPage(accountID: "local", arguments: ["statuses": .array([.string("queued")])])
            #expect(topLevel.objectValue?["threads"]?.arrayValue?.isEmpty == true)
            let all = try store.toolThreadPage(accountID: "local", arguments: [
                "statuses": .array([.string("queued")]), "include_subagents": .bool(true),
            ])
            #expect(all.objectValue?["threads"]?.arrayValue?.count == 1)
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

        @Test(arguments: ["chat_items", "chat_threads"])
        func manualRunOpeningAndChoicesCommitAtomically(failingTable: String) throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let record = thread()
            try store.createThread(record)
            try store.updateThread(id: record.id, model: "old-model", effort: "low")
            var manual = run(target: record.id)
            manual.status = "running"
            manual.model = "chosen-model"
            manual.effort = "high"
            manual.input = try ChatHistoryCodec.encodeInputs([.text("Work")])
            try store.dbQueue.write { db in
                let operation = failingTable == "chat_items" ? "INSERT" : "UPDATE"
                try db.execute(sql: "CREATE TRIGGER fail_opening BEFORE \(operation) ON \(failingTable) BEGIN SELECT RAISE(ABORT, 'opening failed'); END")
            }
            #expect(throws: (any Error).self) { try store.beginUserRun(manual, message: ChatHistoryCodec.user([.text("Work")])) }
            #expect(try store.run(id: manual.id) == nil)
            #expect(try store.listItems(threadID: record.id).isEmpty)
            #expect(try store.thread(id: record.id, accountID: record.accountID).model == "old-model")
            #expect(try store.thread(id: record.id, accountID: record.accountID).reasoningEffort == "low")
            try store.dbQueue.write { try $0.execute(sql: "DROP TRIGGER fail_opening") }
            _ = try store.beginUserRun(manual, message: ChatHistoryCodec.user([.text("Work")]))
            #expect(try store.thread(id: record.id, accountID: record.accountID).model == "chosen-model")
            #expect(try store.thread(id: record.id, accountID: record.accountID).reasoningEffort == "high")
            // Crash immediately after acceptance, before Pi or the turn broadcaster can start.
            try store.recoverInterruptedThreads(continuing: true)
            let continuation = try #require(try store.queuedRuns(accountID: record.accountID).first)
            #expect(continuation.model == "chosen-model" && continuation.effort == "high")
            #expect(try store.listItems(threadID: record.id).count == 1)
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

        /// As T3 Code's "Continue threads after restarts": a cut-short run continues, a queued one still starts, and one
        /// that cannot continue tells its requester.
        @Test func aCrashContinuesCutShortRunsUnlessTheyWaitedWereStoppedOrKeepCrashing() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let parent = thread(), worker = thread(), waiting = thread(), stopped = thread(), crashing = thread()
            for record in [parent, worker, waiting, stopped, crashing] {
                try store.createThread(record)
            }
            func saved(_ target: String, _ status: String, requester: String? = nil, change: (inout ChatRunRecord) -> Void = { _ in }) throws
                -> ChatRunRecord {
                var item = run(target: target, requester: requester)
                item.status = status
                change(&item)
                return try store.enqueueRun(item)
            }
            let originalInput = try ChatHistoryCodec.encodeInputs([.text("Do work"), .imageDataURI("data:image/png;base64,aW1hZ2U=")])
            let cut = try saved(worker.id, "running", requester: parent.id) {
                $0.approvalMethod = "never"
                $0.input = originalInput
            }
            let asked = try saved(waiting.id, "waitingForUser", requester: parent.id)
            let halted = try saved(stopped.id, "running") { $0.stoppedByUser = true }
            let queued = try saved(parent.id, "queued")
            for _ in 0 ..< 2 {
                _ = try saved(crashing.id, "interrupted") { $0.origin = "restart" }
            }
            let again = try saved(crashing.id, "running") { $0.origin = "restart" }

            try store.recoverInterruptedThreads(continuing: true)

            let continuations = try store.dbQueue.read {
                try ChatRunRecord.fetchAll($0, sql: "SELECT * FROM chat_runs WHERE status = 'queued' AND origin = 'restart'")
            }
            let next = try #require(continuations.first)
            #expect(continuations.count == 1)
            #expect(next.threadID == worker.id && next.requestedByThreadID == parent.id && next.rootRunID == cut.rootRunID)
            #expect(next.input == cut.input && next.approvalMethod == CodexChatApprovalMethod.autoReview.rawValue)
            // The continuation reports for the cut run; the one that waited reports that it was interrupted.
            #expect(try store.run(id: cut.id)?.status == "interrupted" && store.run(id: cut.id)?.resultDeliveredAt != nil)
            #expect(try store.undeliveredRuns(requesterID: parent.id).map(\.id) == [asked.id])
            #expect(try store.run(id: halted.id)?.status == "interrupted")
            #expect(try store.run(id: again.id)?.status == "interrupted")
            #expect(try store.run(id: queued.id)?.status == "queued")
        }

        @Test func repeatedRecoveryKeepsTheOriginalInputAndSkipsRecordsWithoutIt() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let target = thread(), legacy = thread()
            try store.createThread(target)
            try store.createThread(legacy)
            let inputs: [CodexAppServerInput] = [
                .text("Original request"),
                .imageMetadata("Screenshot"),
                .imageDataURI("data:image/png;base64,aW1hZ2U="),
            ]
            var interrupted = run(target: target.id)
            interrupted.status = "running"
            interrupted.input = try ChatHistoryCodec.encodeInputs(inputs)
            _ = try store.enqueueRun(interrupted)
            var incomplete = run(target: legacy.id)
            incomplete.status = "running"
            incomplete.input = ""
            _ = try store.enqueueRun(incomplete)
            try store.recoverInterruptedThreads(continuing: true)
            let first = try #require(try store.queuedRuns(accountID: "local").first)
            #expect(try ChatHistoryCodec.decodeInputs(first.input) == inputs)
            let restored = try store.listItems(threadID: target.id)
            #expect(restored.count == 1 && restored.first?.runID == interrupted.id)
            let opening = try #require(restored.first)
            #expect(try JSONDecoder().decode(JSONValue.self, from: Data(opening.data.utf8)) == ChatHistoryCodec.user(inputs))
            #expect(try store.run(id: incomplete.id)?.status == "interrupted")
            let claimed = try #require(try store.claimQueuedRun(first))
            try store.setRunStatus(claimed.id, status: "running")
            try store.recoverInterruptedThreads(continuing: true)
            let second = try #require(try store.queuedRuns(accountID: "local").first)
            #expect(second.input == first.input)
            #expect(try first.logicalSequence == store.run(id: interrupted.id)?.logicalSequence)
            #expect(second.logicalSequence == first.logicalSequence)
            try store.setRunStatus(second.id, status: "completed")
            #expect(try store.run(id: second.id)?.input.isEmpty == true)
        }

        @Test(arguments: [false, true])
        func repeatedRecoveryPreservesQueueAndResultBatchOrder(queuedBeforeManual: Bool) throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let parent = thread(), target = thread()
            try store.createThread(parent)
            try store.createThread(target)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            var original = run(target: target.id, requester: parent.id)
            original.createdAt = now.addingTimeInterval(-2)
            original.status = "running"
            original.input = try ChatHistoryCodec.encodeInputs([.text("Research")])
            if !queuedBeforeManual { _ = try store.enqueueRun(original) }
            var followUp = run(target: target.id, requester: parent.id)
            followUp.createdAt = now.addingTimeInterval(-1)
            _ = try store.enqueueRun(followUp)
            if queuedBeforeManual { _ = try store.enqueueRun(original) }
            let tail = try store.enqueueRun(run(target: target.id, requester: parent.id))
            try store.recoverInterruptedThreads(continuing: true, now: now)
            let first = try #require(try store.queuedRuns(accountID: "local").first)
            #expect(first.origin == "restart")
            _ = try #require(try store.claimQueuedRun(first))
            try store.recoverInterruptedThreads(continuing: true, now: now.addingTimeInterval(1))
            let second = try #require(try store.queuedRuns(accountID: "local").first)
            #expect(second.id != first.id && second.logicalSequence == first.logicalSequence)
            #expect(second.executionSequence != nil && second.executionSequence == first.executionSequence)
            #expect(try second.executionSequence == (store.run(id: original.id)?.executionSequence))
            #expect(second.createdAt == now.addingTimeInterval(1))
            #expect(try store.queuedRuns(accountID: "local").map(\.id) == [second.id, followUp.id, tail.id])
            #expect(try store.latestRun(threadID: target.id)?.id == tail.id)
            try store.setRunStatus(second.id, status: "completed")
            try store.setRunStatus(followUp.id, status: "completed")
            #expect(try store.undeliveredRuns(requesterID: parent.id).map(\.id) == [second.id, followUp.id])
        }

        @Test func aStoppedRootAlsoPreventsItsRunningDescendantsFromResuming() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let parent = thread(), child = thread()
            try store.createThread(parent)
            try store.createThread(child)
            let root = try store.enqueueRun(run(target: parent.id))
            try store.markStoppedByUser(root.id)
            var delegated = run(target: child.id, requester: parent.id, root: root.id)
            delegated.status = "running"
            _ = try store.enqueueRun(delegated)
            try store.recoverInterruptedThreads(continuing: true)
            #expect(try store.queuedRuns(accountID: "local").allSatisfy { $0.origin != "restart" })
            #expect(try store.run(id: delegated.id)?.status == "interrupted")
        }

        @Test func idleLaunchKeysSurviveReloadAndStayWithinTheirRequesterAndRoot() throws {
            let db = try AppDatabaseManager(path: ":memory:").dbQueue
            let store = ChatThreadStore(dbQueue: db)
            let caller = thread(), target = thread(), other = thread()
            for record in [caller, target, other] {
                try store.createThread(record)
            }
            let root = UUID.v7()
            try store.recordIdleLaunch(threadID: target.id, requesterID: caller.id, rootRunID: root, clientRequestID: "once")
            let reloaded = ChatThreadStore(dbQueue: db)
            #expect(try reloaded.idleLaunch(requesterID: caller.id, rootRunID: root, clientRequestID: "once") == target.id)
            #expect(try reloaded.idleLaunch(requesterID: other.id, rootRunID: root, clientRequestID: "once") == nil)
            #expect(try reloaded.idleLaunch(requesterID: caller.id, rootRunID: .v7(), clientRequestID: "once") == nil)
            #expect(throws: (any Error).self) { _ = try reloaded.requestedRun(requesterID: caller.id, rootRunID: root, clientRequestID: "once") }
            #expect(throws: (any Error).self) {
                try reloaded.recordIdleLaunch(threadID: other.id, requesterID: caller.id, rootRunID: root, clientRequestID: "once")
            }
            try store.deleteThread(id: target.id)
            #expect(try reloaded.idleLaunch(requesterID: caller.id, rootRunID: root, clientRequestID: "once") == nil)
        }

        /// As T3 Code's Settled shelf: a settled thread leaves the active list, un-settling brings it back to the top, and any
        /// run that starts in it makes it active again.
        @Test func aSettledThreadLeavesTheActiveListUntilItIsUnsettledOrARunStarts() throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let older = thread(), newer = thread()
            try store.createThread(older)
            try store.createThread(newer)
            func active() throws -> [String] { try store.listThreads(accountID: "local", cursor: nil).threads.map(\.id) }

            try store.setSettled(true, threadID: older.id, accountID: "local")
            #expect(try active() == [newer.id])
            #expect(try store.listThreads(accountID: "local", cursor: nil, settled: true).threads.map(\.id) == [older.id])
            #expect(try store.threadCounts(accountID: "local") == (1, 1))

            try store.setSettled(false, threadID: older.id, accountID: "local")
            #expect(try active() == [older.id, newer.id])
            #expect(try store.threadCounts(accountID: "local") == (2, 0))

            try store.setSettled(true, threadID: newer.id, accountID: "local")
            let started = try store.enqueueRun(run(target: newer.id))
            try store.setRunStatus(started.id, status: "running")
            #expect(try active().first == newer.id && store.threadCounts(accountID: "local") == (2, 0))
        }

        @Test(arguments: ["queued", "running", "waitingForUser"])
        func outstandingWorkCannotBeSettled(status: String) throws {
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let target = thread()
            try store.createThread(target)
            let work = try store.enqueueRun(run(target: target.id))
            try store.setRunStatus(work.id, status: status)

            #expect(throws: ChatThreadStore.SettleError.threadBusy) {
                try store.setSettled(true, threadID: target.id, accountID: "local")
            }
            #expect(try store.thread(id: target.id, accountID: "local").settledAt == nil)
            try store.setSettled(false, threadID: target.id, accountID: "local")
            try store.setRunStatus(work.id, status: "completed")
            try store.setSettled(true, threadID: target.id, accountID: "local")
            #expect(try store.thread(id: target.id, accountID: "local").settledAt != nil)
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
