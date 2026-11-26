import DahliaRuntimeSupport
import Foundation
import GRDB
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct PiChatServiceTests {
        private static func history() throws -> ChatThreadStore {
            try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
        }

        struct Fixture {
            let pi: TestPiRuntime
            let chat: PiChatService
            let chatTransport: TestPiTransport
            let store: ChatThreadStore
        }

        /// The chat process answers every command and runs `onPrompt` for user prompts.
        static func fixture(
            customInstructions: @escaping @Sendable () -> String = { "" },
            commands: JSONValue? = nil,
            delaysCommands: Bool = false,
            promptNotifications: [JSONValue] = [],
            promptDisposition: String = "started",
            onPrompt: @escaping @Sendable (TestPiTransport) async -> Void
        ) throws -> Fixture {
            let chatTransport = TestPiTransport { command in
                guard let id = command["id"] else { return [] }
                if command["type"]?.stringValue == "get_commands", delaysCommands { return [] }
                if command["type"]?.stringValue == "get_commands", let commands {
                    return [TestPiTransport.response(id: id, data: .object(["commands": commands]))]
                }
                let notifications = command["type"]?.stringValue == "prompt" ? promptNotifications : []
                return notifications + [TestPiTransport.response(id: id, data: .object(["disposition": .string(promptDisposition)]))]
            }
            let pi = TestPiRuntime { options in
                switch options.mode {
                case .chat: chatTransport
                default: TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "gpt-test")]))
                }
            }
            let store = try Self.history()
            let chat = PiChatService(
                runtime: pi.service,
                historyStore: store,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                reviewModel: { "reviewer/test-model" },
                customInstructions: customInstructions,
                mcpSettings: { AgentMCPSettings() },
                fileAccessSettings: { PiFileAccessSettings() }
            )
            Task {
                // A user prompt starts the scripted turn; extension commands start with "/".
                let prompt = await chatTransport.command {
                    $0["type"]?.stringValue == "prompt" && $0["message"]?.stringValue?.hasPrefix("/") == false
                }
                guard !prompt.isEmpty else { return }
                await onPrompt(chatTransport)
            }
            return Fixture(pi: pi, chat: chat, chatTransport: chatTransport, store: store)
        }

        @Test(arguments: [false, true])
        func recoveryRetainsTheRequestAndImageBeforePiAcknowledgesItsPrompt(rejectSteer: Bool) async throws {
            let store = try Self.history()
            let original = TestPiTransport { command in
                if command["type"] == .string("prompt") { return [] }
                if rejectSteer, command["type"] == .string("steer") {
                    return [.object([
                        "type": .string("response"),
                        "id": command["id"] ?? .null,
                        "command": .string("steer"),
                        "success": .bool(false),
                        "error": .string("Rejected"),
                    ])]
                }
                return TestPiTransport.acknowledge(command)
            }
            let resumed = TestPiTransport()
            let models = TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "gpt-test")])
            let firstPi = TestPiRuntime { $0.mode == .chat ? original : TestPiTransport(reply: models) }
            let secondPi = TestPiRuntime { $0.mode == .chat ? resumed : TestPiTransport(reply: models) }
            defer {
                try? FileManager.default.removeItem(at: firstPi.rootURL)
                try? FileManager.default.removeItem(at: secondPi.rootURL)
            }
            func service(_ pi: TestPiRuntime) -> PiChatService {
                PiChatService(
                    runtime: pi.service,
                    historyStore: store,
                    workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                    agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                    mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                    mcpSettings: { .init() },
                    fileAccessSettings: { .init() }
                )
            }
            let first = service(firstPi)
            let thread = try await first.startThread(model: nil, effort: "medium")
            let inputs: [CodexAppServerInput] = [
                .text("REQUEST_BEFORE_PI_ACK"),
                .imageMetadata("Screenshot"),
                .imageDataURI("data:image/png;base64,aW1hZ2U="),
            ]
            let starting = Task {
                try await first.beginTurn(threadID: thread.id, inputs: inputs, model: nil, effort: "medium", approvalMethod: .ask)
            }
            _ = await original.command("prompt")
            let running = try #require(try store.latestRun(threadID: thread.id))
            #expect(running.status == "running")
            #expect(try ChatHistoryCodec.decodeInputs(running.input) == inputs)
            if rejectSteer {
                await #expect(throws: (any Error).self) {
                    try await first.steer(threadID: thread.id, turnID: "", inputs: [.text("STEER_INSTRUCTION")])
                }
            } else {
                try await first.steer(threadID: thread.id, turnID: "", inputs: [.text("STEER_INSTRUCTION")])
            }
            // A replacement Pi starts without the first process's session file or any accepted prompt.
            try store.recoverInterruptedThreads(continuing: true)
            let replacement = service(secondPi)
            await replacement.scheduleRuns(accountID: AppAccount.key)
            if rejectSteer {
                #expect(await resumed.commands.allSatisfy { $0["type"] != .string("prompt") })
                #expect(try store.run(id: running.id)?.status == "interrupted")
            } else {
                let prompt = await resumed.command("prompt")
                let text = try #require(prompt["message"]?.stringValue)
                #expect(text.contains(ChatThreadStore.continuePrompt) && text.contains("REQUEST_BEFORE_PI_ACK") && text.contains("STEER_INSTRUCTION"))
                #expect(prompt["images"]?.arrayValue?.first?.objectValue?["data"] == .string("aW1hZ2U="))
            }
            await first.closeSession(thread.id)
            _ = try? await starting.value
            await replacement.closeSession(thread.id)
        }

        @Test(arguments: ["edited", "deleted", "locked", "interrupted"])
        func rejectedOptimizerProposalFinishesItsRun(change: String) async throws {
            let fixture = try Self.fixture { _ in }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let root = URL(filePath: PiSandbox.realPath(fixture.pi.rootURL)).appending(path: "skills")
            let service = try await fixture.chat.skillService()
            let raw = "---\nname: sample\ndescription: Review sample input.\n---\nReview the input."
            _ = try await service.execute("skill_manage", payload: .object(["operations": .array([.object([
                "action": .string("create"), "name": .string("sample"), "content": .string(raw),
            ])])]), account: "local", root: root, thread: nil)
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            _ = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Optimize sample")], model: nil, effort: "medium",
                approvalMethod: .ask
            )
            let turn = try #require(await fixture.chat.sessions[thread.id]?.turn?.run)
            let input = try await fixture.chat.optimizerInput(.object(["name": .string("sample")]), run: turn, account: "local", root: root)
            let id = try #require(input.objectValue?["run_id"]?.stringValue)
            #expect(input.objectValue?["raw"] == .string(raw))
            switch change {
            case "edited": try (raw + "\nNew instructions.").write(to: root.appending(path: "sample/SKILL.md"), atomically: true, encoding: .utf8)
            case "deleted": try FileManager.default.removeItem(at: root.appending(path: "sample"))
            case "locked": try await service.setLocked(name: "sample", account: "local", locked: true)
            default: await fixture.chat.closeSession(thread.id)
            }
            let payload: JSONValue = .object([
                "run_id": .string(id), "name": .string("sample"), "changed": .bool(true),
                "constraints": .array([.object(["passed": .bool(true)])]), "improvement": .number(0.2), "skill": .string(raw + "\nValidate."),
            ])
            let result = try await fixture.chat.optimizerResult(payload, account: "local", root: root)
            #expect(change == "interrupted" ? result == .bool(false) : result.objectValue?["success"] == .bool(false))
            let run = try await fixture.store.dbQueue.read { try #require(try AgentSystemRunRecord.fetchOne($0, key: id)) }
            #expect(run.status == (change == "interrupted" ? "interrupted" : "failed"))
            #expect(run.finishedAt != nil)
            #expect(run.report.isEmpty)
            #expect(try await fixture.store.dbQueue.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM agent_learning_changes WHERE reviewID=?", arguments: [id])
            } == 0)
            #expect(try await fixture.chat.optimizerResult(payload, account: "local", root: root) == .bool(false))
            await fixture.chat.closeSession(thread.id)
            await fixture.pi.service.shutdown()
        }

        @Test(arguments: [CodexChatApprovalMethod.ask, .autoReview, .fullAccess])
        func scheduleApprovalCommitsOnlyTheFrozenRequestOnce(method: CodexChatApprovalMethod) async throws {
            let fixture = try Self.fixture { _ in }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            _ = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Create a reminder")], model: nil, effort: "medium",
                approvalMethod: method
            )
            let process = try #require(await fixture.chat.sessions[thread.id]?.processID)
            let schedules = AgentScheduleService(dbQueue: fixture.store.dbQueue)
            let prepared = try await fixture.chat.learningTool("cronjob", payload: .object([
                "action": .string("create"), "prompt": .string("Read the meeting"), "schedule": .string("30m"),
                "_readOnlyTools": .array([.string("mcp__dahlia__get_meeting")]),
            ]), threadID: thread.id, processID: process)
            let id = try #require(prepared.objectValue?["request_id"]?.stringValue)
            let arguments = prepared.objectValue?["approval"]?.objectValue?["arguments"]?.objectValue
            #expect(arguments?["prompt"] == .string("Read the meeting"))
            #expect(arguments?["approved_read_only_tools"] == .array([.string("mcp__dahlia__get_meeting")]))
            #expect(arguments?["_readOnlyTools"] == nil)
            #expect(try schedules.list(account: "local").isEmpty)
            #expect(await fixture.chat.sessions[thread.id]?.turn?.pendingApprovals.isEmpty == true)
            let commit: JSONValue = .object([
                "request_id": .string(id), "approved": .bool(true), "prompt": .string("Do something else"),
                "_readOnlyTools": .array([.string("mcp__dahlia__update_meeting")]),
            ])
            _ = try await fixture.chat.learningTool("cronjobCommit", payload: commit, threadID: thread.id, processID: process)
            let saved = try #require(try schedules.list(account: "local").first)
            #expect(saved.prompt == "Read the meeting")
            #expect(saved.allowedTools == "[\"mcp__dahlia__get_meeting\"]")
            await #expect(throws: (any Error).self) {
                try await fixture.chat.learningTool("cronjobCommit", payload: commit, threadID: thread.id, processID: process)
            }
            await fixture.chat.closeSession(thread.id)
            await fixture.pi.service.shutdown()
        }

        @Test(arguments: ["update", "resume"], [false, true])
        func scheduleReviewIncludesOmittedFieldsAndChecksRevisions(action: String, changed: Bool) async throws {
            let fixture = try Self.fixture { _ in }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            _ = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Change the reminder")], model: nil, effort: "medium",
                approvalMethod: .autoReview
            )
            let process = try #require(await fixture.chat.sessions[thread.id]?.processID)
            let schedules = AgentScheduleService(dbQueue: fixture.store.dbQueue)
            _ = try schedules.execute(.object([
                "action": .string("create"), "prompt": .string("Original prompt"), "schedule": .string("30m"),
                "skills": .array([.string("meeting-reviewer")]),
            ]), account: "local", approved: true, tools: [])
            let saved = try #require(try schedules.list(account: "local").first)
            if action == "resume" {
                _ = try schedules.execute(
                    .object(["action": .string("pause"), "job_id": .string(saved.id)]),
                    account: "local",
                    approved: false,
                    tools: []
                )
            }
            var payload: [String: JSONValue] = ["action": .string(action), "job_id": .string(saved.id)]
            if action == "resume" {
                // Resume ignores update-only fields: review the saved task that will actually run.
                payload["prompt"] = .string("Ignored prompt")
                payload["schedule"] = .string("every day at 9am")
                payload["skills"] = .array([])
                payload["name"] = .string("Ignored name")
            }
            let prepared = try await fixture.chat.learningTool("cronjob", payload: .object(payload), threadID: thread.id, processID: process)
            let arguments = prepared.objectValue?["approval"]?.objectValue?["arguments"]?.objectValue
            #expect(arguments?["prompt"] == .string(saved.prompt))
            #expect(arguments?["schedule"] == .string(saved.schedule))
            #expect(arguments?["skills"] == .array([.string("meeting-reviewer")]))
            if action == "resume" { #expect(arguments?["name"] == .string(saved.name)) }
            let id = try #require(prepared.objectValue?["request_id"]?.stringValue)
            let commit: JSONValue = .object(["request_id": .string(id), "approved": .bool(true)])
            if changed {
                _ = try schedules.execute(
                    .object(["action": .string("pause"), "job_id": .string(saved.id)]),
                    account: "local",
                    approved: false,
                    tools: []
                )
                await #expect(throws: (any Error).self) {
                    try await fixture.chat.learningTool("cronjobCommit", payload: commit, threadID: thread.id, processID: process)
                }
                #expect(try schedules.record(id: saved.id, account: "local").enabled == false)
            } else {
                _ = try await fixture.chat.learningTool("cronjobCommit", payload: commit, threadID: thread.id, processID: process)
                let activated = try schedules.record(id: saved.id, account: "local")
                #expect(activated.enabled == true)
                #expect(activated.prompt == saved.prompt)
                #expect(activated.schedule == saved.schedule)
                #expect(activated.skills == saved.skills)
                #expect(activated.name == saved.name)
            }
            await fixture.chat.closeSession(thread.id)
            await fixture.pi.service.shutdown()
        }

        @Test(arguments: ["declined", "stopped", "wrongProcess"])
        func scheduleCommitRejectsDeclinedOrObsoleteApprovals(state: String) async throws {
            let fixture = try Self.fixture { _ in }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            _ = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Set a reminder")], model: nil, effort: "medium",
                approvalMethod: .autoReview
            )
            let process = try #require(await fixture.chat.sessions[thread.id]?.processID)
            let prepared = try await fixture.chat.learningTool("cronjob", payload: .object([
                "action": .string("create"), "prompt": .string("Read only"), "schedule": .string("30m"),
            ]), threadID: thread.id, processID: process)
            let id = try #require(prepared.objectValue?["request_id"]?.stringValue)
            if state == "stopped" { await fixture.chat.abort(threadID: thread.id) }
            for approved in [false, true] {
                await #expect(throws: (any Error).self) {
                    try await fixture.chat.learningTool("cronjobCommit", payload: .object([
                        "request_id": .string(id), "approved": .bool(approved),
                    ]), threadID: thread.id, processID: state == "wrongProcess" ? .v7() : process)
                }
            }
            #expect(try AgentScheduleService(dbQueue: fixture.store.dbQueue).list(account: "local").isEmpty)
            await fixture.chat.closeSession(thread.id)
            await fixture.pi.service.shutdown()
        }

        @Test
        func lateSubscriberGetsSavedHistoryPartialTextAndFutureEvents() async throws {
            let fixture = try Self.fixture { transport in
                await transport.emit(.object(["type": .string("message_update"), "assistantMessageEvent": .object([
                    "type": .string("text_delta"), "delta": .string("partial"),
                ])]))
            }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let lease = await fixture.chat.acquireThreadLease(threadID: thread.id)
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("Question")],
                model: nil,
                effort: "medium",
                approvalMethod: .ask
            )
            var first = handle.events.makeAsyncIterator()
            while let event = try await first.next() {
                if case .delta = event { break }
            }
            let attached = try #require(await fixture.chat.attach(threadID: thread.id))
            #expect(attached.id == handle.id)
            #expect(attached.snapshot?.messages.map(\.text) == ["Question"])
            let savedPage = try fixture.store.messagePage(threadID: thread.id)
            #expect(savedPage.lastItemSeq != nil)
            #expect(attached.snapshot?.lastItemSeq == savedPage.lastItemSeq)
            await fixture.chat.releaseThreadLease(threadID: thread.id, leaseID: lease)
            await fixture.chatTransport.emit(TestPiTransport.assistantEnd("Saved answer"))
            await fixture.chatTransport.emit(TestPiTransport.settled())
            var events: [CodexChatTurnEvent] = []
            for try await event in attached.events {
                events.append(event)
            }
            #expect(events.contains { if case .delta(_, "partial") = $0 { true } else { false } })
            #expect(events.last?.terminalCompletion == true)
            #expect(try fixture.store.latestRun(threadID: thread.id)?.status == "completed")
            #expect(try fixture.store.messagePage(threadID: thread.id).messages.last?.text == "Saved answer")
        }

        @Test(arguments: [false, true])
        func attachmentReplaysCompactionOnlyWhileItIsActive(alreadyCompacted: Bool) async throws {
            let fixture = try Self.fixture { transport in
                await transport.emit(.object(["type": .string("compaction_start"), "reason": .string("threshold")]))
            }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Question")], model: nil, effort: "medium", approvalMethod: .ask
            )
            var first = handle.events.makeAsyncIterator()
            while let event = try await first.next() {
                if event == .compactionStarted { break }
            }
            let result = CodexChatCompaction(tokensBefore: 900, tokensAfter: 300)
            let end: JSONValue = .object([
                "type": .string("compaction_end"), "reason": .string("threshold"),
                "result": .object(["tokensBefore": .number(900), "estimatedTokensAfter": .number(300)]),
            ])
            if alreadyCompacted {
                await fixture.chatTransport.emit(end)
                while let event = try await first.next() {
                    if event == .compactionEnded(result) { break }
                }
            }
            let attached = try #require(await fixture.chat.attach(threadID: thread.id))
            if alreadyCompacted {
                #expect(attached.snapshot?.messages.map(\.role) == [.user, .compaction(result)])
            } else {
                await fixture.chatTransport.emit(end)
            }
            await fixture.chatTransport.emit(TestPiTransport.assistantEnd("Done"))
            await fixture.chatTransport.emit(TestPiTransport.settled())
            var replay: [CodexChatTurnEvent] = []
            for try await event in attached.events {
                replay.append(event)
            }
            #expect(replay.contains(.compactionStarted) == !alreadyCompacted)
            #expect(replay.contains(.compactionEnded(result)) == !alreadyCompacted)
            #expect(replay.last?.terminalCompletion == true)
        }

        @Test
        func serviceRetainsApprovalForLaterAttachmentAndResolvesItOnce() async throws {
            let fixture = try Self.fixture { _ in }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("Question")],
                model: nil,
                effort: "medium",
                approvalMethod: .ask
            )
            await fixture.chatTransport.emit(TestPiTransport.bridgeRequest(id: "approval-card", method: "approval", payload: .object([
                "kind": .string("mcpToolCall"), "server": .string("dahlia"), "tool": .string("update_meeting"), "arguments": .object([:]),
            ])))
            var first = handle.events.makeAsyncIterator()
            var request: CodexChatApprovalRequest?
            while let event = try await first.next() {
                if case let .approvalRequested(value) = event { request = value
                    break
                }
            }
            let approval = try #require(request)
            let attached = try #require(await fixture.chat.attach(threadID: thread.id))
            var late = attached.events.makeAsyncIterator()
            var restored: CodexChatApprovalRequest?
            while let event = try await late.next() {
                if case let .approvalRequested(value) = event { restored = value
                    break
                }
            }
            #expect(restored?.id == approval.id)
            try await fixture.chat.decideApproval(turnID: attached.id, id: approval.id, decision: .accept)
            await #expect(throws: PiRuntimeError.approvalNoLongerPending) {
                try await fixture.chat.decideApproval(turnID: attached.id, id: approval.id, decision: .accept)
            }
            await fixture.chatTransport.emit(TestPiTransport.settled())
            while try await late.next() != nil {}
        }

        @Test
        func hiddenRunCanBeSteeredWithoutASubscriber() async throws {
            let fixture = try Self.fixture { _ in }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("First")],
                model: nil,
                effort: "medium",
                approvalMethod: .ask
            )
            try await fixture.chat.steer(threadID: thread.id, turnID: "unused", inputs: [.text("Follow-up")])
            let command = await fixture.chatTransport.command("steer")
            #expect(command["message"] == .string("Follow-up"))
            await fixture.chatTransport.emit(TestPiTransport.assistantEnd("Result"))
            await fixture.chatTransport.emit(TestPiTransport.settled())
            for try await _ in handle.events {}
            #expect(try fixture.store.messagePage(threadID: thread.id).messages.last?.text == "Follow-up")
        }

        @Test
        func historyPagesMessagesPastUnrenderableToolLogs() async throws {
            let fixture = try Self.fixture { _ in }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            try fixture.store.appendItems(threadID: thread.id, items: (0 ..< 95).map { ChatHistoryCodec.user([.text("message \($0)")]) })
            try fixture.store.appendItems(threadID: thread.id, items: (0 ..< 200).map { _ in
                .object(["type": .string("tool_result"), "result": .string("tool output")])
            })
            try fixture.store.appendItems(threadID: thread.id, items: (0 ..< 100).map { _ in
                .object(["type": .string("message"), "role": .string("assistant"), "content": .string("")])
            })
            let latest = try await fixture.chat.loadThread(id: thread.id)
            #expect(latest.messages.map(\.text) == (55 ..< 95).map { "message \($0)" })
            let cursor = try #require(latest.earlierMessagesCursor)
            let earlier = try await fixture.chat.loadEarlierMessages(threadID: thread.id, cursor: cursor)
            #expect(earlier.messages.map(\.text) == (15 ..< 55).map { "message \($0)" })
            let earliest = try await fixture.chat.loadEarlierMessages(threadID: thread.id, cursor: #require(earlier.earlierCursor))
            #expect(earliest.messages.map(\.text) == (0 ..< 15).map { "message \($0)" })
            #expect(earliest.earlierCursor == nil)
        }

        @Test
        func historyPersistsWithoutAViewAndRestoresFromGRDB() async throws {
            let fixture = try Self.fixture { transport in
                await transport.emit(.object(["type": .string("message_update"), "assistantMessageEvent": .object([
                    "type": .string("text_delta"), "delta": .string("partial"),
                ])]))
                await transport.emit(TestPiTransport.assistantEnd("Saved answer"))
                await transport.emit(.object([
                    "type": .string("tool_execution_end"), "toolName": .string("read"), "toolCallId": .string("call1"),
                    "isError": .bool(true), "result": .object(["content": .array([.object([
                        "type": .string("text"), "text": .string("Operation not permitted"),
                    ])])]),
                ]))
                await transport.emit(TestPiTransport.settled())
            }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            await fixture.chat.setThreadName(threadID: thread.id, name: "Saved title")
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("Question")],
                model: nil,
                effort: "medium",
                approvalMethod: .ask
            )
            for try await _ in handle.events {}
            let items = try fixture.store.listItems(threadID: thread.id)
            #expect(items.count == 3)
            #expect(try fixture.store.thread(id: thread.id, accountID: "local").status == "idle")
            let tool = try JSONDecoder().decode(JSONValue.self, from: Data(items[2].data.utf8))
            #expect(tool.objectValue?["status"]?.stringValue == "inaccessible")
            let restored = try await fixture.chat.loadThread(id: thread.id)
            #expect(restored.title == "Saved title")
            #expect(restored.messages.map(\.text) == ["Question", "Saved answer"])
            #expect(try await fixture.chat.listThreads(cursor: nil).threads.map(\.id) == [thread.id])
        }

        @Test
        func historyWriteFailureFinishesWithAnErrorInsteadOfReportingSuccess() async throws {
            let fixture = try Self.fixture { transport in
                await transport.emit(TestPiTransport.assistantEnd("Cannot save"))
                await transport.emit(TestPiTransport.settled())
            }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            try await fixture.store.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_chat_assistant BEFORE INSERT ON chat_items
                WHEN json_extract(new.data, '$.role') = 'assistant' BEGIN
                    SELECT RAISE(ABORT, 'simulated disk failure');
                END;
                """)
            }
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("Question")],
                model: nil,
                effort: "medium",
                approvalMethod: .ask
            )
            await #expect(throws: (any Error).self) {
                for try await _ in handle.events {}
            }
            #expect(try fixture.store.thread(id: thread.id, accountID: "local").status == "failed")
            #expect(try fixture.store.listItems(threadID: thread.id).count == 1)
        }

        @Test(arguments: [false, true])
        func missingResumeFileCannotRestartACompletedThreadWithEmptyContext(processFailsBeforeSettling: Bool) async throws {
            let fixture = try Self.fixture { transport in
                await transport.emit(TestPiTransport.assistantEnd("Saved"))
                if processFailsBeforeSettling {
                    await transport.close()
                } else {
                    await transport.emit(TestPiTransport.settled())
                }
            }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("Question")],
                model: nil,
                effort: "medium",
                approvalMethod: .ask
            )
            if processFailsBeforeSettling {
                await #expect(throws: (any Error).self) {
                    for try await _ in handle.events {}
                }
            } else {
                for try await _ in handle.events {}
                await fixture.chat.unsubscribe(threadID: thread.id)
            }
            let directory = try PiAgentDirectoryLocator(applicationSupportURL: fixture.pi.rootURL).sessionsURL()
            let file = try #require(PiChatSessionFiles.file(id: thread.id, in: directory))
            try FileManager.default.removeItem(at: file)
            await #expect(throws: (any Error).self) {
                try await fixture.chat.beginTurn(
                    threadID: thread.id,
                    inputs: [.text("Continue")],
                    model: nil,
                    effort: "medium",
                    approvalMethod: .ask
                )
            }
            #expect(try await fixture.chat.loadThread(id: thread.id).messages.last?.text == "Saved")
            #expect(fixture.pi.launches.all.count(where: { $0.mode == .chat }) == 1)
        }

        @Test
        func steerIsStoredAfterTheReplyItInterrupted() async throws {
            @Sendable func userEnd(_ text: String) -> JSONValue {
                .object(["type": .string("message_end"), "message": .object(["role": .string("user"), "content": .string(text)])])
            }
            let fixture = try Self.fixture { transport in
                await transport.emit(userEnd("Question"))
                _ = await transport.command("steer")
                await transport.emit(TestPiTransport.assistantEnd("Before"))
                await transport.emit(userEnd("Steer"))
                await transport.emit(TestPiTransport.assistantEnd("After"))
                await transport.emit(TestPiTransport.settled())
            }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("Question")],
                model: nil,
                effort: "medium",
                approvalMethod: .ask
            )
            try await fixture.chat.steer(threadID: thread.id, turnID: "x", inputs: [.text("Steer")])
            for try await _ in handle.events {}
            let messages = try fixture.store.messagePage(threadID: thread.id).messages
            #expect(messages.map(\.text) == ["Question", "Before", "Steer", "After"])
            #expect(messages.map(\.isSteer) == [false, false, true, false])
        }

        @Test
        func acceptedSteerSurvivesAProcessLossBeforeDelivery() async throws {
            let fixture = try Self.fixture { transport in
                _ = await transport.command("steer")
                await transport.close()
            }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("Question")],
                model: nil,
                effort: "medium",
                approvalMethod: .ask
            )
            try await fixture.chat.steer(threadID: thread.id, turnID: "x", inputs: [.text("Steer")])
            await #expect(throws: (any Error).self) {
                for try await _ in handle.events {}
            }
            let messages = try fixture.store.messagePage(threadID: thread.id).messages
            #expect(messages.map(\.text) == ["Question", "Steer"])
            #expect(messages.map(\.isSteer) == [false, true])
            #expect(try fixture.store.thread(id: thread.id, accountID: "local").status == "failed")
        }

        @Test
        func stoppedTurnKeepsTheUserMessageAndRecordsAnInterruption() async throws {
            let fixture = try Self.fixture { transport in
                _ = await transport.command("abort")
                await transport.emit(TestPiTransport.settled(aborted: true))
            }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("Question")],
                model: nil,
                effort: "medium",
                approvalMethod: .ask
            )
            await fixture.chat.stopTurn(handle.id)
            for try await _ in handle.events {}
            #expect(try fixture.store.thread(id: thread.id, accountID: "local").status == "interrupted")
            #expect(try fixture.store.listItems(threadID: thread.id).count == 1)

            // Pi never replied, so it left no resume file: the Thread starts Pi anew instead of becoming read-only.
            await fixture.chat.unsubscribe(threadID: thread.id)
            let record = try fixture.store.thread(id: thread.id, accountID: "local")
            let directory = try PiAgentDirectoryLocator(applicationSupportURL: fixture.pi.rootURL)
                .sessionsURL()
            if let file = PiChatSessionFiles.file(id: thread.id, in: directory) { try FileManager.default.removeItem(at: file) }
            // The test transport serves one process, so only the relaunch itself is observable here.
            _ = try? await fixture.chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("Again")],
                model: nil,
                effort: "medium",
                approvalMethod: .ask
            )
            #expect(fixture.pi.launches.all.count(where: { $0.mode == .chat }) == 2)
        }

        @Test
        func piFilesDoNotOverwriteDatabaseHistoryAndMissingFilesPreventExecution() async throws {
            let fixture = try Self.fixture { _ in }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let directory = try PiAgentDirectoryLocator(applicationSupportURL: fixture.pi.rootURL).sessionsURL(workspaceID: .v7())
            let id = UUID.v7().uuidString.lowercased()
            try fixture.store.createThread(ChatThreadRecord(
                id: id, accountID: "local",
                title: "Database title", createdAt: .now, updatedAt: .now
            ), items: [
                ChatHistoryCodec.user([.text("Original question")]),
                ChatHistoryCodec.message(["role": .string("assistant"), "content": .string("Original answer")]),
            ])
            let file = directory.appending(path: "2026-01-01_\(id).jsonl")
            let lines = [
                "{\"type\":\"session\",\"id\":\"\(id)\"}",
                #"{"type":"message","id":"u1","message":{"role":"user","content":"Pi question"}}"#,
                #"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"text","text":"Pi answer"}]}}"#,
                #"{"type":"session_info","name":"Original name"}"#,
            ].joined(separator: "\n")
            try Data(lines.utf8).write(to: file)
            let first = try await fixture.chat.listThreads(cursor: nil)
            #expect(first.threads.map(\.id) == [id])
            #expect(first.threads.first?.title == "Database title")
            await fixture.chat.setThreadName(threadID: id, name: "Catalog title")
            _ = try await fixture.chat.listThreads(cursor: nil)
            #expect(try fixture.store.listItems(threadID: id).count == 2)
            #expect(try await fixture.chat.resumeThread(id: id).title == "Catalog title")
            try FileManager.default.removeItem(at: file)
            #expect(try await fixture.chat.loadThread(id: id).messages.map(\.text) == ["Original question", "Original answer"])
            await #expect(throws: (any Error).self) {
                try await fixture.chat.beginTurn(
                    threadID: id,
                    inputs: [.text("Continue")],
                    model: nil,
                    effort: "medium",
                    approvalMethod: .ask
                )
            }
            #expect(fixture.pi.launches.all.isEmpty)
        }

        @Test
        func backupBridgeUsesAnExplicitWorkspaceFromTheChatAccount() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            defer { try? database.close() }
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Chat", createdAt: .now, lastOpenedAt: .now)
            let other = WorkspaceRecord(id: .v7(), path: nil, name: "Other", createdAt: .now, lastOpenedAt: .now)
            try await database.dbQueue.write { db in
                try workspace.insert(db)
                try other.insert(db)
            }
            let result = Mutex<String?>(nil)
            let fixture = try Self.fixture { transport in
                await transport.emit(TestPiTransport.bridgeRequest(
                    id: "backup",
                    method: "createBackup",
                    payload: .object(["workspace_id": .string(TypeID.encode(workspace.id, as: .workspace))])
                ))
                let response = await transport.command { $0["id"]?.stringValue == "backup" }
                result.withLock { $0 = response["value"]?.stringValue }
                await transport.emit(TestPiTransport.assistantEnd("Created"))
                await transport.emit(TestPiTransport.settled())
            }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            await fixture.chat.configureBackup(dbQueue: database.dbQueue, applicationSupportURL: fixture.pi.rootURL)
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Back up this workspace")], model: nil, effort: "medium",
                approvalMethod: .ask
            )
            for try await _ in handle.events {}
            let response = try #require(result.withLock { $0 })
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
            let path = try #require(value.objectValue?["path"]?.stringValue)
            #expect(path.hasSuffix(".tar.gz"))
            #expect(URL(fileURLWithPath: path).deletingLastPathComponent().path == fixture.pi.rootURL.appending(path: "work").path)
            let manifest = try BackupArchive.readManifest(at: URL(fileURLWithPath: path))
            #expect(manifest.metadata.workspaces.map(\.id) == [workspace.id])
            #expect(try await BackupService(dbQueue: database.dbQueue, applicationSupportURL: fixture.pi.rootURL).listGenerations().count == 1)
        }

        @Test(arguments: ["", " \n\t", "日本語で簡潔に回答してください。\nUse bullet points when helpful.", "existing-file"])
        func customInstructionsUseAppendSystemPromptWithoutChangingTheUserMessage(input: String) async throws {
            let fileURL = URL.temporaryDirectory.appending(path: "dahlia-instructions-\(UUID.v7()).txt")
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let instructions: String
            if input == "existing-file" {
                try "File contents must not become instructions".write(to: fileURL, atomically: true, encoding: .utf8)
                instructions = fileURL.path
            } else {
                instructions = input
            }
            let fixture = try Self.fixture(customInstructions: { instructions }) { transport in
                await transport.emit(TestPiTransport.assistantEnd("Done"))
                await transport.emit(TestPiTransport.settled())
            }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let turn = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Hello")], model: nil, effort: "medium",
                approvalMethod: .ask
            )
            for try await _ in turn.events {}
            let launch = try #require(fixture.pi.launches.all.first { $0.mode == .chat })
            let promptIndex = try #require(launch.arguments.firstIndex(of: "--system-prompt"))
            let prompt = launch.arguments[promptIndex + 1]
            #expect(prompt.hasPrefix(PiChatService.systemPrompt))
            #expect(prompt.contains("Dahlia's database:"))
            #expect(prompt.contains("Dahlia's screenshots:"))
            #expect(!prompt.contains("# User's custom instructions for AI chat"))
            let appendedPrompts = launch.arguments.indices.filter { launch.arguments[$0] == "--append-system-prompt" }
                .map { launch.arguments[$0 + 1] }
            let customPrompts = appendedPrompts.filter { $0.hasPrefix("\n\n# User's custom instructions for AI chat\n") }
            if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                #expect(customPrompts.isEmpty)
            } else {
                #expect(customPrompts.count == 1)
                let appended = try #require(customPrompts.first)
                #expect(appended == "\n\n# User's custom instructions for AI chat\n" + instructions)
                #expect(!FileManager.default.fileExists(atPath: appended))
            }
            let command = await fixture.chatTransport.command("prompt")
            #expect(command["message"]?.stringValue == "Hello")
        }

        @Test(arguments: ["info", "warning", "error", "unknown"])
        func handledMCPCommandPreservesNotificationsBeforeFinishingWithoutAnAgentRun(notifyType: String) async throws {
            let fixture = try Self.fixture(promptNotifications: [
                .object([
                    "type": .string("extension_ui_request"),
                    "id": .string("status"),
                    "method": .string("notify"),
                    "notifyType": .string(notifyType),
                    "message": .string("dahlia: connected\n12 tools"),
                ]),
            ], promptDisposition: "handled") { _ in }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let turn = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("/mcp")], model: nil, effort: "medium", approvalMethod: .ask
            )
            var events: [CodexChatTurnEvent] = []
            for try await event in turn.events {
                events.append(event)
            }
            #expect(events.count == 3)
            #expect(events.contains(.notice(message: "dahlia: connected\n12 tools", level: CodexChatNoticeLevel(rawValue: notifyType) ?? .info)))
            #expect(events.last == .completed(itemID: nil, text: nil))
        }

        @Test
        func providerRefreshDoesNotCloseAChatReplacedDuringAnotherChatsClose() async throws {
            let transports = TestPiTransportLog()
            let closes = Mutex(0)
            let (closing, didClose) = AsyncStream<String>.makeStream()
            let (release, proceed) = AsyncStream<Void>.makeStream()
            let pi = TestPiRuntime { options in
                guard options.mode == .chat else {
                    return TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "gpt-test")]))
                }
                let index = options.arguments.firstIndex(of: "--session-id")
                let threadID = index.map { options.arguments[$0 + 1] } ?? "resumed"
                let transport = TestPiTransport(onClose: {
                    let first = closes.withLock { value in
                        value += 1
                        return value == 1
                    }
                    if first {
                        didClose.yield(threadID)
                        var iterator = release.makeAsyncIterator()
                        _ = await iterator.next()
                    }
                }) { command in
                    guard let id = command["id"] else { return [] }
                    return [TestPiTransport.response(id: id, data: .object(["disposition": .string("started")]))]
                }
                transports.append(transport)
                return transport
            }
            let chat = try PiChatService(
                runtime: pi.service, historyStore: Self.history(),
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { AgentMCPSettings() }, fileAccessSettings: { PiFileAccessSettings() }
            )
            var threads: [CodexChatThread] = []
            var leases: [UUID] = []
            for index in 0 ..< 2 {
                let thread = try await chat.startThread(model: "openai/gpt-test", effort: "medium")
                threads.append(thread)
                await leases.append(chat.acquireThreadLease(threadID: thread.id))
                let turn = try await chat.beginTurn(
                    threadID: thread.id, inputs: [.text("Initial")], model: nil, effort: "medium", approvalMethod: .ask
                )
                let process = await transports.transport(at: index)
                await process.emit(TestPiTransport.assistantEnd("Done"))
                await process.emit(TestPiTransport.settled())
                for try await _ in turn.events {}
            }
            let refresh = Task { await chat.providerAccountsDidChange() }
            var iterator = closing.makeAsyncIterator()
            let closedID = try #require(await iterator.next())
            let other = try #require(threads.first { $0.id != closedID })
            let next = try await chat.beginTurn(
                threadID: other.id, inputs: [.text("Next")], model: nil, effort: "medium", approvalMethod: .ask
            )
            proceed.yield()
            await refresh.value
            let process = try #require(transports.all.last)
            #expect(await !process.isClosed)
            await process.emit(TestPiTransport.assistantEnd("Still running"))
            await process.emit(TestPiTransport.settled())
            for try await _ in next.events {}
            for (thread, lease) in zip(threads, leases) {
                await chat.releaseThreadLease(threadID: thread.id, leaseID: lease)
            }
        }

        @Test(arguments: [false, true])
        func providerChangesDuringPreparationRefreshTheNextTurn(preparationFails: Bool) async throws {
            let transports = TestPiTransportLog()
            let pi = TestPiRuntime { options in
                guard options.mode == .chat else {
                    return TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "gpt-test")]))
                }
                let first = transports.all.isEmpty
                let held = Mutex(false)
                let transport = TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    if first, command["type"]?.stringValue == "set_thinking_level", held.withLock({ value in
                        defer { value = true }
                        return !value
                    }) { return [] }
                    return [TestPiTransport.response(id: id, data: .object(["disposition": .string("started")]))]
                }
                transports.append(transport)
                return transport
            }
            let chat = try PiChatService(
                runtime: pi.service,
                historyStore: Self.history(),
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { AgentMCPSettings() },
                fileAccessSettings: { PiFileAccessSettings() }
            )
            let thread = try await chat.startThread(model: "openai/gpt-test", effort: "medium")
            let lease = await chat.acquireThreadLease(threadID: thread.id)
            let preparing = Task {
                try await chat.beginTurn(
                    threadID: thread.id, inputs: [.text("First")], model: nil, effort: "high", approvalMethod: .ask
                )
            }
            let first = await transports.transport(at: 0)
            let thinking = await first.command("set_thinking_level")
            await chat.providerAccountsDidChange()
            #expect(await !first.isClosed)
            let commandID = try #require(thinking["id"])
            if preparationFails {
                // No turn reaches endRun: the idle, leased process must still retain its invalidation.
                await first.emit(.object([
                    "type": .string("response"), "id": commandID, "success": .bool(false), "error": .string("Setup failed"),
                ]))
                await #expect(throws: (any Error).self) { try await preparing.value }
            } else {
                await first.emit(TestPiTransport.response(id: commandID))
                let turn = try await preparing.value
                #expect(await !first.isClosed)
                await first.emit(TestPiTransport.assistantEnd("Done"))
                await first.emit(TestPiTransport.settled())
                for try await _ in turn.events {}
            }

            let next = try await chat.beginTurn(
                threadID: thread.id, inputs: [.text("Next")], model: nil, effort: "medium", approvalMethod: .ask
            )
            try #require(pi.launches.all.count(where: { $0.mode == .chat }) == 2)
            #expect(await first.isClosed)
            let second = await transports.transport(at: 1)
            await second.emit(TestPiTransport.assistantEnd("Fresh providers"))
            await second.emit(TestPiTransport.settled())
            for try await _ in next.events {}
            await chat.releaseThreadLease(threadID: thread.id, leaseID: lease)
        }

        @Test
        func commandDiscoveryUsesChatResourcesWithoutCreatingAThreadOrPrompt() async throws {
            let fixture = try Self.fixture(commands: .array([
                .object(["name": .string("skill:summary"), "source": .string("skill"), "description": .string("Summarize")]),
                .object(["name": .string("mcp"), "source": .string("extension")]),
            ])) { _ in }
            let commands = try await fixture.chat.commands(threadID: nil)
            #expect(commands.map(\.name) == ["mcp", "skill:summary"])
            let launch = try #require(fixture.pi.launches.all.first { $0.mode == .chat })
            #expect(launch.arguments.contains("--no-session"))
            #expect(launch.arguments.contains("--skill"))
            let creator = try #require(PiBundle.presetSkillURLs().first { $0.lastPathComponent == "skill-creator" })
            #expect(launch.arguments.contains(creator.path))
            #expect(try launch.arguments.contains(AgentMCPElicitationSettings.entryURL().path))
            #expect(await fixture.chatTransport.isClosed)
            #expect(await fixture.chatTransport.commands.allSatisfy { ["get_state", "get_commands"].contains($0["type"]?.stringValue ?? "") })
        }

        @Test
        func malformedCommandDiscoveryStillClosesItsTemporaryProcess() async throws {
            let fixture = try Self.fixture(commands: .array([.object(["name": .string("missing-source")])])) { _ in }
            await #expect(throws: (any Error).self) {
                try await fixture.chat.commands(threadID: nil)
            }
            #expect(await fixture.chatTransport.isClosed)
        }

        @Test
        func cancellingCommandDiscoveryClosesItsTemporaryProcess() async throws {
            let fixture = try Self.fixture(delaysCommands: true) { _ in }
            let task = Task { try await fixture.chat.commands(threadID: nil) }
            _ = await fixture.chatTransport.command("get_commands")
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(await fixture.chatTransport.isClosed)
        }

        /// Pi reads its providers when it starts: after a provider account changes, an idle chat closes and reopens with
        /// it on its next message, and a running turn finishes on its process first.
        @Test
        func providerChangesCloseIdleChatsAndRunningOnesAfterTheirTurn() async throws {
            let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
            let fixture = try Self.fixture { transport in
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
                await transport.emit(TestPiTransport.assistantEnd("Done"))
                await transport.emit(TestPiTransport.settled())
            }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let lease = await fixture.chat.acquireThreadLease(threadID: thread.id)
            let turn = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Hello")], model: nil, effort: "medium",
                approvalMethod: .ask
            )

            await fixture.chat.providerAccountsDidChange()
            #expect(await !fixture.chatTransport.isClosed)

            releaseContinuation.yield()
            for try await _ in turn.events {}
            #expect(await pollUntil { await fixture.chatTransport.isClosed })
            await fixture.chat.releaseThreadLease(threadID: thread.id, leaseID: lease)
        }

        @Test
        func providerChangesCloseAnIdleChatAtOnce() async throws {
            let fixture = try Self.fixture { transport in
                await transport.emit(TestPiTransport.assistantEnd("Done"))
                await transport.emit(TestPiTransport.settled())
            }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let lease = await fixture.chat.acquireThreadLease(threadID: thread.id)
            let turn = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Hello")], model: nil, effort: "medium",
                approvalMethod: .ask
            )
            for try await _ in turn.events {}
            #expect(await !fixture.chatTransport.isClosed)

            await fixture.chat.providerAccountsDidChange()
            #expect(await fixture.chatTransport.isClosed)
            await fixture.chat.releaseThreadLease(threadID: thread.id, leaseID: lease)
        }

        @Test
        func commandDiscoveryReusesTheOpenThreadWithoutClosingIt() async throws {
            let fixture = try Self.fixture(commands: .array([])) { transport in
                await transport.emit(TestPiTransport.assistantEnd("Done"))
                await transport.emit(TestPiTransport.settled())
            }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let lease = await fixture.chat.acquireThreadLease(threadID: thread.id)
            let turn = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Hello")], model: nil, effort: "medium",
                approvalMethod: .ask
            )
            for try await _ in turn.events {}
            #expect(try await fixture.chat.commands(threadID: thread.id).map(\.name) == ["compact"])
            #expect(fixture.pi.launches.all.filter { $0.mode == .chat }.count == 1)
            #expect(await !fixture.chatTransport.isClosed)
            await fixture.chat.releaseThreadLease(threadID: thread.id, leaseID: lease)
        }

        @Test
        func deniedToolReportsActivityAndTheTurnStillCompletes() async throws {
            let fixture = try Self.fixture { transport in
                await transport.emit(.object([
                    "type": .string("tool_execution_start"), "toolName": .string("bash"), "toolCallId": .string("c"),
                ]))
                await transport.emit(.object([
                    "type": .string("tool_execution_end"), "toolName": .string("bash"), "toolCallId": .string("c"),
                    "isError": .bool(true), "result": .object(["content": .array([.object([
                        "type": .string("text"), "text": .string("ls: agent: Operation not permitted\nCommand exited with code 1"),
                    ])])]),
                ]))
                await transport.emit(TestPiTransport.assistantEnd("Access was denied."))
                await transport.emit(TestPiTransport.settled())
            }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("inspect agent")], model: nil, effort: "medium",
                approvalMethod: .ask
            )
            var events: [CodexChatTurnEvent] = []
            for try await event in handle.events {
                events.append(event)
            }
            #expect(events.contains(.toolActivity(.init(name: "bash", status: .running, callID: "c"))))
            #expect(events.contains(.toolActivity(.init(
                name: "bash", status: .inaccessible, callID: "c",
                output: "ls: agent: Operation not permitted\nCommand exited with code 1"
            ))))
            #expect(events.contains { if case .completed(itemID: .some, text: "Access was denied.") = $0 { true } else { false } })
            #expect(events.last == .completed(itemID: nil, text: nil))
        }

        @Test(arguments: [
            (false, "Operation not permitted", CodexChatToolActivity.Status.succeeded),
            (true, "Permission denied", .inaccessible),
            (true, "Cannot read /agent/auth.json", .inaccessible),
            (true, "ENOENT: file not found", .failed),
        ])
        func toolResultDistinguishesFailureFromOutput(isError: Bool, text: String, expected: CodexChatToolActivity.Status) {
            let event: [String: JSONValue] = [
                "type": .string("tool_execution_end"), "toolName": .string("read"), "isError": .bool(isError),
                "result": .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])])]),
            ]
            #expect(PiChatService.toolActivity(event) == .init(name: "read", status: expected, output: text))
            #expect(PiChatService.toolActivity(["type": .string("message_end"), "toolName": .string("read")]) == nil)
        }

        @Test
        func turnStreamsTextAndReasoningThenCompletes() async throws {
            let fixture = try Self.fixture { transport in
                await transport.emit(.object(["type": .string("message_update"), "assistantMessageEvent": .object([
                    "type": .string("thinking_delta"), "delta": .string("think"),
                ])]))
                await transport.emit(.object(["type": .string("message_update"), "assistantMessageEvent": .object([
                    "type": .string("text_delta"), "delta": .string("Hel"),
                ])]))
                await transport.emit(TestPiTransport.assistantEnd("Hello"))
                await transport.emit(TestPiTransport.settled())
            }
            let thread = try await fixture.chat.startThread(model: "openai/gpt-test", effort: "medium")
            _ = await fixture.chat.acquireThreadLease(threadID: thread.id)

            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("<context>\n</context>"), .text("Hi")],
                model: "openai/gpt-test",
                effort: "high",
                approvalMethod: .autoReview
            )
            var events: [CodexChatTurnEvent] = []
            for try await event in handle.events {
                events.append(event)
            }

            #expect(events.count == 5)
            guard events.count == 5, case .started = events[0] else { return }
            #expect(events[1] == .reasoningDelta(itemID: events.itemID(1), summaryIndex: 0, text: "think"))
            #expect(events[2] == .delta(itemID: events.itemID(1), text: "Hel"))
            #expect(events[3] == .completed(itemID: events.itemID(1), text: "Hello"))
            #expect(events[4] == .completed(itemID: nil, text: nil))
            let prompt = await fixture.chatTransport.commands.last { $0["type"]?.stringValue == "prompt" }
            #expect(prompt?["message"]?.stringValue == "<context>\n</context>\nHi")
            let thinking = await fixture.chatTransport.command("set_thinking_level")
            #expect(thinking["level"]?.stringValue == "high")
            let launch = try #require(fixture.pi.launches.all.first { $0.mode == .chat })
            #expect(launch.arguments.contains("--session-id"))
            #expect(launch.arguments
                .contains(
                    "read,ls,write,edit,bash,skills_list,skill_view,skill_manage,cronjob,skill_optimize,memory,dah_create_backup,thread_list,thread_search,thread_read,"
                        + "thread_launch,delegate_task,task_status,task_cancel,thread_send,thread_wait,thread_interrupt,thread_update,mcp__dahlia__*"
                ))
            let work = fixture.pi.rootURL.appending(path: "work")
            #expect(launch.cwd == work)
            #expect(try launch.arguments.contains(AgentMCPElicitationSettings.entryURL().path))
            #expect(launch.environment["DAHLIA_PI_MCP_COMMAND"]?.contains("--account") == false)
            // Commands and file tools run under Seatbelt, confined to the working folder.
            #expect(launch.fileAccess.grants.isEmpty)
            #expect(launch.environment["DAHLIA_PI_MCP_SERVERS"] == #"["dahlia"]"#)
            // The Local Account has no gateway MCPs; its mcp.json lists none.
            let mcpJSON = try PiAgentDirectoryLocator(applicationSupportURL: fixture.pi.rootURL)
                .agentURL().appending(path: "mcp.json")
            #expect(FileManager.default.contents(atPath: mcpJSON.path) == Data(#"{"mcpServers":{}}"#.utf8))
        }

        @Test
        func fileAccessChangesReopenExistingThreadsBeforeTheNextTurn() async throws {
            let permissions = Mutex(PiFileAccessSettings())
            let transports = TestPiTransportLog()
            let pi = TestPiRuntime { options in
                guard options.mode == .chat else {
                    return TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "gpt-test")]))
                }
                let transport = TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    if command["type"]?.stringValue == "get_commands" {
                        return [TestPiTransport.response(id: id, data: .object(["commands": .array([])]))]
                    }
                    return [TestPiTransport.response(id: id, data: .object(["disposition": .string("started")]))]
                }
                transports.append(transport)
                return transport
            }
            let chat = try PiChatService(
                runtime: pi.service,
                historyStore: Self.history(),
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { AgentMCPSettings() },
                fileAccessSettings: { permissions.withLock { $0 } }
            )
            let thread = try await chat.startThread(model: "openai/gpt-test", effort: "medium")
            let lease = await chat.acquireThreadLease(threadID: thread.id)
            let readOnly = PiFileAccessSettings(grants: [.init(path: "/private/tmp/desk-config.toml", isDirectory: false)])
            var readWrite = readOnly
            readWrite.grants[0].access = .readWrite
            for (index, configuration) in [PiFileAccessSettings(), readOnly, readWrite, PiFileAccessSettings()].enumerated() {
                permissions.withLock { $0 = configuration }
                let handle = try await chat.beginTurn(
                    threadID: thread.id, inputs: [.text("Hi")], model: nil, effort: "medium", approvalMethod: .ask
                )
                let process = await transports.transport(at: index)
                let launch = try #require(pi.launches.all.last { $0.mode == .chat })
                #expect(launch.fileAccess == configuration)
                #expect(launch.arguments.contains { $0.contains("desk-config.toml") } == !configuration.grants.isEmpty)
                if index == 0 {
                    // Saving a grant does not interrupt a running turn or its command discovery.
                    permissions.withLock { $0 = readOnly }
                    #expect(try await chat.commands(threadID: thread.id).isEmpty)
                    #expect(await !process.isClosed)
                }
                await process.emit(TestPiTransport.assistantEnd("ok"))
                await process.emit(TestPiTransport.settled())
                for try await _ in handle.events {}
                #expect(pi.launches.all.count(where: { $0.mode == .chat }) == index + 1)
                if index > 0 { #expect(await transports.all[index - 1].isClosed) }
            }
            await chat.releaseThreadLease(threadID: thread.id, leaseID: lease)
        }

        @Test
        func aModelTurnedOnAfterTheProcessStartedReopensTheThread() async throws {
            let launches = Atomic<Int>(0)
            let reopened = TestPiTransportLog()
            let pi = TestPiRuntime { options in
                guard options.mode == .chat else {
                    return TestPiTransport(reply: TestPiRuntime.modelsReply([
                        TestPiTransport.model(provider: "openai", id: "gpt-test"),
                        TestPiTransport.model(provider: "openai", id: "gpt-new"),
                    ]))
                }
                // The first process read models.json before `gpt-new` was turned on; the reopened one knows it.
                let isFirst = launches.add(1, ordering: .relaxed).newValue == 1
                let transport = TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    if isFirst, command["type"]?.stringValue == "set_model" {
                        return [.object([
                            "type": .string("response"), "id": id, "command": .string("set_model"), "success": .bool(false),
                            "error": .string("Model not found: openai/gpt-new"),
                        ])]
                    }
                    if command["type"]?.stringValue == "prompt", command["message"]?.stringValue?.hasPrefix("/") == false {
                        return [TestPiTransport.response(id: id, data: .object(["disposition": .string("started")]))]
                    }
                    return [TestPiTransport.response(id: id)]
                }
                if !isFirst { reopened.append(transport) }
                return transport
            }
            let chat = try PiChatService(
                runtime: pi.service,
                historyStore: Self.history(),
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { AgentMCPSettings() },
                fileAccessSettings: { PiFileAccessSettings() }
            )
            let thread = try await chat.startThread(model: "openai/gpt-test", effort: "medium")
            _ = await chat.acquireThreadLease(threadID: thread.id)

            let handle = try await chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("Hi")],
                model: "openai/gpt-new",
                effort: "medium",
                approvalMethod: .autoReview
            )
            // The reopened process runs the turn with the approval method the turn asked for.
            let process = await reopened.transport(at: 0)
            await process.emit(TestPiTransport.bridgeRequest(id: "m1", method: "approvalMode", payload: .object([:])))
            #expect(await process.command { $0["id"]?.stringValue == "m1" }["value"]?.stringValue == #""autoReview""#)
            await process.emit(TestPiTransport.assistantEnd("Hello"))
            await process.emit(TestPiTransport.settled())
            var events: [CodexChatTurnEvent] = []
            for try await event in handle.events {
                events.append(event)
            }

            #expect(events.last == .completed(itemID: nil, text: nil))
            #expect(pi.launches.all.count(where: { $0.mode == .chat }) == 2)
        }

        @Test
        func askModeRoutesApprovalsToTheUserAndAnswersPi() async throws {
            let fixture = try Self.fixture { transport in
                await transport.emit(TestPiTransport.bridgeRequest(id: "ui-7", method: "approval", payload: .object([
                    "kind": .string("commandExecution"), "command": .string("ls"), "cwd": .string("/tmp"),
                ])))
                _ = await transport.command("extension_ui_response")
                await transport.emit(TestPiTransport.assistantEnd("done"))
                await transport.emit(TestPiTransport.settled())
            }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")

            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("run ls")], model: nil, effort: "medium",
                approvalMethod: .ask
            )
            var sawResolution = false
            for try await event in handle.events {
                if case let .approvalRequested(request) = event {
                    #expect(request.kind == .commandExecution)
                    #expect(request.command == "ls")
                    #expect(request.actions == [.allowOnce, .deny])
                    try await fixture.chat.decideApproval(turnID: handle.id, id: request.id, decision: .accept)
                }
                if case .approvalResolved = event { sawResolution = true }
            }

            #expect(sawResolution)
            #expect(await fixture.chatTransport.commands.allSatisfy { $0["message"]?.stringValue?.hasPrefix("/") != true })
            let response = await fixture.chatTransport.command("extension_ui_response")
            #expect(response["id"]?.stringValue == "ui-7")
            #expect(response["value"]?.stringValue == #""accept""#)
        }

        @Test
        func failedRunStatusSaveCancelsTheRemovedApprovalWaiter() async throws {
            let fixture = try Self.fixture { _ in }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Change data")], model: nil,
                effort: "medium", approvalMethod: .ask
            )
            await fixture.chatTransport.emit(TestPiTransport.bridgeRequest(id: "failing-approval", method: "approval", payload: .object([
                "kind": .string("mcpToolCall"), "server": .string("dahlia"), "tool": .string("update_meeting"), "arguments": .object([:]),
            ])))
            var reader = handle.events.makeAsyncIterator()
            var request: CodexChatApprovalRequest?
            while let event = try await reader.next() {
                if case let .approvalRequested(value) = event { request = value
                    break
                }
            }
            let approval = try #require(request)
            try await fixture.store.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_run_approval BEFORE UPDATE OF status ON chat_runs WHEN NEW.status = 'running'
                BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END;
                """)
            }
            await #expect(throws: (any Error).self) {
                try await fixture.chat.decideApproval(turnID: handle.id, id: approval.id, decision: .accept)
            }
            #expect(await pollUntil {
                await fixture.chatTransport.commands
                    .contains { $0["type"]?.stringValue == "extension_ui_response" && $0["id"]?.stringValue == "failing-approval" }
            })
            let response = await fixture.chatTransport.commands
                .first { $0["id"]?.stringValue == "failing-approval" && $0["type"]?.stringValue == "extension_ui_response" }
            #expect(response?["value"]?.stringValue == #""cancel""#)
            #expect(await fixture.chat.sessions[thread.id]?.turn?.pendingApprovals.isEmpty == true)
            #expect(await fixture.chat.sessions[thread.id]?.turn?.broadcast.approvals.isEmpty == true)
            await fixture.chat.stopAccountRuns(except: "other")
        }

        @Test
        func approvalModeChangedDuringATurnAppliesToTheNextToolCall() async throws {
            let fixture = try Self.fixture { _ in }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("/dahlia-approval autoReview")], model: nil, effort: "medium",
                approvalMethod: .ask
            )
            func mode(_ id: String) async -> String? {
                await fixture.chatTransport.emit(TestPiTransport.bridgeRequest(id: id, method: "approvalMode", payload: .object([:])))
                return await fixture.chatTransport.command { $0["id"]?.stringValue == id }["value"]?.stringValue
            }

            #expect(await mode("m1") == #""ask""#)
            _ = try await fixture.chat.updateApprovalMethod(threadID: thread.id, approvalMethod: .autoReview)
            #expect(await mode("m2") == #""autoReview""#)
            _ = try await fixture.chat.updateApprovalMethod(threadID: thread.id, approvalMethod: .fullAccess)
            #expect(await mode("m3") == #""fullAccess""#)
            await fixture.chatTransport.emit(TestPiTransport.bridgeRequest(id: "review-model", method: "reviewModel", payload: .object([:])))
            let modelResponse = await fixture.chatTransport.command { $0["id"]?.stringValue == "review-model" }
            let modelValue = try #require(modelResponse["value"]?.stringValue)
            #expect(try JSONDecoder().decode(String.self, from: Data(modelValue.utf8)) == "reviewer/test-model")

            let prompt = await fixture.chatTransport.command { $0["type"]?.stringValue == "prompt" }
            #expect(prompt["message"]?.stringValue == "/dahlia-approval autoReview")
            await fixture.chatTransport.emit(TestPiTransport.settled())
            for try await _ in handle.events {}
        }

        @Test
        func stoppingDeclinesPendingApprovalsAndAbortsPi() async throws {
            let fixture = try Self.fixture { transport in
                await transport.emit(TestPiTransport.bridgeRequest(id: "ui-8", method: "approval", payload: .object([
                    "kind": .string("fileChange"), "path": .string("/tmp/a.txt"), "change": .string("add"), "diff": .string("+a"),
                ])))
                _ = await transport.command("abort")
                await transport.emit(TestPiTransport.settled(aborted: true))
            }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")

            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("write")], model: nil, effort: "medium",
                approvalMethod: .ask
            )
            var last: CodexChatTurnEvent?
            for try await event in handle.events {
                if case let .approvalRequested(request) = event {
                    #expect(request.fileChanges == [.init(path: "/tmp/a.txt", diff: "+a", kind: .add)])
                    #expect(request.actions == [.allowOnce, .allowSameFilesForSession, .deny])
                    await fixture.chat.stopTurn(handle.id)
                }
                last = event
            }

            #expect(last == .interrupted)
            let response = await fixture.chatTransport.command("extension_ui_response")
            #expect(response["value"]?.stringValue == #""cancel""#)
        }

        @Test
        func steeringWithoutActiveTurnReportsNoActiveTurn() async throws {
            let fixture = try Self.fixture { _ in }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            await #expect(throws: PiRuntimeError.rpcError(code: nil, message: "no active turn to steer")) {
                try await fixture.chat.steer(threadID: thread.id, turnID: "x", inputs: [.text("more")])
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func stoppingBeforeThePromptIsAcknowledgedClosesItsPiProcess() async throws {
            let log = TestPiTransportLog()
            let pi = TestPiRuntime { options in
                let transport = options.mode == .chat
                    ? TestPiTransport { command in
                        // Pi never acknowledges the first process's prompt; every other command succeeds.
                        guard let id = command["id"], command["type"]?.stringValue != "prompt" || log.all.count > 1 else { return [] }
                        let started = TestPiTransport.response(id: id, data: .object(["disposition": .string("started")]))
                        return command["type"]?.stringValue == "prompt"
                            ? [started, TestPiTransport.assistantEnd("next"), TestPiTransport.settled()] : [started]
                    }
                    : TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "gpt-test")]))
                if options.mode == .chat { log.append(transport) }
                return transport
            }
            let chat = try PiChatService(
                runtime: pi.service,
                historyStore: Self.history(),
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true")
            )
            let thread = try await chat.startThread(model: nil, effort: "medium")
            _ = await chat.acquireThreadLease(threadID: thread.id)

            let stopped = Task {
                try await chat.beginTurn(
                    threadID: thread.id, inputs: [.text("hi")], model: nil, effort: "medium",
                    approvalMethod: .ask
                )
            }
            let first = await log.transport(at: 0)
            _ = await first.command("prompt")
            stopped.cancel()
            _ = try? await stopped.value

            #expect(await first.isClosed)
            let next = try await chat.beginTurn(
                threadID: thread.id, inputs: [.text("again")], model: nil, effort: "medium",
                approvalMethod: .ask
            )
            for try await _ in next.events {}
            #expect(log.all.count == 2)
        }

        @Test(.providerAccounts([.init(id: UUID(), workspaceURL: URL(string: "https://own.cloud.databricks.com")!)]), arguments: [false, true])
        func turnReopensTheThreadAfterItsPiProcessExits(legacyDirectory: Bool) async throws {
            let log = TestPiTransportLog()
            let pi = TestPiRuntime { options in
                let transport = options.mode == .chat
                    ? TestPiTransport { command in
                        guard let id = command["id"] else { return [] }
                        let started = TestPiTransport.response(id: id, data: .object(["disposition": .string("started")]))
                        let isUserPrompt = command["type"]?.stringValue == "prompt"
                            && command["message"]?.stringValue?.hasPrefix("/") == false
                        return isUserPrompt ? [started, TestPiTransport.assistantEnd("again"), TestPiTransport.settled()] : [started]
                    }
                    : TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "own.cloud.databricks.com", id: "gpt-test")]))
                if options.mode == .chat { log.append(transport) }
                return transport
            }
            let registered = Mutex(AgentMCPSettings())
            let omnigentEnabled = Mutex(false)
            let chat = try PiChatService(
                runtime: pi.service,
                historyStore: Self.history(),
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { registered.withLock { $0 } },
                omnigentConnection: { omnigentEnabled.withLock { $0 } ? UUID() : nil }
            )
            let thread = try await chat.startThread(model: nil, effort: "medium")
            _ = await chat.acquireThreadLease(threadID: thread.id)
            let sessions = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL)
                .sessionsURL()
            let first = try await chat.beginTurn(
                threadID: thread.id, inputs: [.text("hi")], model: nil, effort: "medium",
                approvalMethod: .autoReview
            )
            for try await _ in first.events {}
            var file = try #require(PiChatSessionFiles.file(id: thread.id, in: sessions))
            if legacyDirectory {
                let legacy = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL).sessionsURL(workspaceID: .v7())
                    .appending(path: file.lastPathComponent)
                try FileManager.default.moveItem(at: file, to: legacy)
                file = legacy
            }
            #expect(pi.launches.all.last { $0.mode == .chat }?.arguments.contains("--session-id") == true)

            try await pi.service.reloadConfiguration(interruptActiveOperations: true)
            let handle = try await chat.beginTurn(
                threadID: thread.id, inputs: [.text("hello")], model: nil, effort: "medium",
                approvalMethod: .autoReview
            )
            var last: CodexChatTurnEvent?
            for try await event in handle.events {
                last = event
            }

            #expect(last == .completed(itemID: nil, text: nil))
            #expect(log.all.count == 2)
            let reopened = try #require(pi.launches.all.last { $0.mode == .chat })
            let sessionArgument = try #require(reopened.arguments.firstIndex(of: "--session"))
            let reopenedFile = URL(filePath: reopened.arguments[sessionArgument + 1])
            #expect(reopenedFile.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)
            let helperCommand = try #require(reopened.environment["DAHLIA_PI_MCP_COMMAND"])
            #expect(!helperCommand.contains("--account"))
            #expect(!helperCommand.contains("--workspace-id"))

            /// A settings change leaves the open process alone; the next process the thread starts uses the new MCPs.
            func turn(_ text: String) async throws {
                let handle = try await chat.beginTurn(
                    threadID: thread.id, inputs: [.text(text)], model: nil, effort: "medium",
                    approvalMethod: .autoReview
                )
                for try await _ in handle.events {}
            }
            let provider = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://example.cloud.databricks.com")))
            registered.withLock {
                $0.providers = [provider]
                $0.servers = [
                    AgentMCPServer(id: .v7(), name: "gmail", providerID: provider.id, service: "system.ai.gmail"),
                    AgentMCPServer(id: .v7(), name: "notion", providerID: provider.id, service: "main.default.notion"),
                ]
            }
            try await turn("gmail on, same process")
            #expect(log.all.count == 2)
            try await pi.service.reloadConfiguration(interruptActiveOperations: true)
            try await turn("gmail on, new process")
            #expect(log.all.count == 3)
            let withGmail = try #require(pi.launches.all.last { $0.mode == .chat })
            #expect(withGmail.arguments
                .contains(
                    "read,ls,write,edit,bash,skills_list,skill_view,skill_manage,cronjob,skill_optimize,memory,dah_create_backup,thread_list,thread_search,thread_read,"
                        + "thread_launch,delegate_task,task_status,task_cancel,thread_send,thread_wait,thread_interrupt,thread_update,mcp__dahlia__*,mcp__gmail__*,mcp__notion__*"
                ))
            // Dahlia's extension registers the sign-ins mcp.json names in every process; none loads the provider file on its own.
            #expect(pi.launches.all.allSatisfy { !$0.arguments.contains { $0.hasSuffix("databricks-provider.ts") } })
            #expect(withGmail.environment["DAHLIA_PI_MCP_SERVERS"] == #"["dahlia","gmail","notion"]"#)
            // The process snapshot names the sign-in; the shared file cannot broaden concurrent launches.
            #expect(withGmail.environment["DAHLIA_PI_MCP_PROVIDERS"] == nil)
            #expect(withGmail.arguments.contains { $0.hasSuffix("/" + file.lastPathComponent) })
            let mcpJSON = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL).agentURL().appending(path: "mcp.json")
            let written = FileManager.default.contents(atPath: mcpJSON.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(written == #"{"mcpServers":{}}"#)
            let configuration = try #require(withGmail.environment["DAHLIA_PI_MCP_CONFIG"])
            let entries = try JSONDecoder().decode(JSONValue.self, from: Data(configuration.utf8)).objectValue
            #expect(entries?["notion"]?
                .objectValue?["url"] == .string("https://example.cloud.databricks.com/ai-gateway/mcp-services/main.default.notion"))
            #expect(entries?["notion"]?.objectValue?["auth"]?.objectValue?["provider"] == .string(provider.id))
            #expect(configuration.contains(#""provider":"example.cloud.databricks.com""#))

            // Turning Omnigent on reaches the next process.
            omnigentEnabled.withLock { $0 = true }
            try await pi.service.reloadConfiguration(interruptActiveOperations: true)
            try await turn("omnigent on, new process")
            let withOmnigent = try #require(pi.launches.all.last { $0.mode == .chat })
            #expect(withOmnigent.arguments.contains {
                $0.contains("thread_update,omni_list_agents,omni_list_sessions,omni_get_session,omni_create_session,mcp__dahlia__*")
            })
        }

        @Test
        func restoringHistoryStartsNoProcess() async throws {
            let fixture = try Self.fixture { _ in }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            await fixture.chat.setThreadName(threadID: thread.id, name: "Named early")
            let restored = try await fixture.chat.resumeThread(id: thread.id)
            #expect(restored.title == "Named early")
            #expect(!fixture.pi.launches.all.contains { $0.mode == .chat })
        }

        @Test
        func releasingTheLastLeaseWhileATurnIsBeingPreparedKeepsItsProcess() async throws {
            // Pi holds `set_thinking_level` until the test answers it, so the release lands inside beginTurn's setup.
            let chatTransport = TestPiTransport { command in
                guard let id = command["id"], command["type"]?.stringValue != "set_thinking_level" else { return [] }
                let started = TestPiTransport.response(id: id, data: .object(["disposition": .string("started")]))
                return command["type"]?.stringValue == "prompt"
                    ? [started, TestPiTransport.assistantEnd("ok"), TestPiTransport.settled()] : [started]
            }
            let pi = TestPiRuntime { options in
                options.mode == .chat ? chatTransport
                    : TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "gpt-test")]))
            }
            let chat = try PiChatService(
                runtime: pi.service,
                historyStore: Self.history(),
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true")
            )
            let thread = try await chat.startThread(model: nil, effort: "medium")
            let lease = await chat.acquireThreadLease(threadID: thread.id)
            let turn = Task {
                try await chat.beginTurn(
                    threadID: thread.id, inputs: [.text("hi")], model: nil, effort: "high",
                    approvalMethod: .autoReview
                )
            }

            let thinking = await chatTransport.command("set_thinking_level")
            await chat.releaseThreadLease(threadID: thread.id, leaseID: lease)
            #expect(await !chatTransport.isClosed)
            try await chatTransport.emit(TestPiTransport.response(id: #require(thinking["id"])))

            var last: CodexChatTurnEvent?
            for try await event in try await turn.value.events {
                last = event
            }
            #expect(last == .completed(itemID: nil, text: nil))
        }

        @Test
        func restoredMessagesKeepEveryAllowedImage() {
            let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
            let image: JSONValue = .object(["type": .string("image"), "data": .string(png), "mimeType": .string("image/png")])
            let content: [JSONValue] = [.object(["type": .string("text"), "text": .string("look")])]
                + Array(repeating: image, count: CodexChatImageAttachment.maximumAttachmentCount)
            let messages = PiChatSessionFiles.messages([[
                "type": .string("message"),
                "id": .string("u1"),
                "message": .object(["role": .string("user"), "content": .array(content)]),
            ]])
            #expect(messages.first?.images.count == CodexChatImageAttachment.maximumAttachmentCount)
        }

        @Test
        func serversNeedingSignInAreReportedAtTheTurnAndAgainAtTheNextOne() async throws {
            let prompts = Mutex(0)
            let chatTransport = TestPiTransport { command in
                guard let id = command["id"] else { return [] }
                let started = TestPiTransport.response(id: id, data: .object(["disposition": .string("started")]))
                guard command["type"]?.stringValue == "prompt" else { return [started] }
                let first = prompts.withLock { count in
                    count += 1
                    return count == 1
                }
                let end = [TestPiTransport.assistantEnd("ok"), TestPiTransport.settled()]
                guard first else { return [started] + end }
                // Pi's notice once servers connect, then a tool call that failed on another server.
                return [
                    started,
                    .object([
                        "type": .string("extension_ui_request"), "id": .string("n"), "method": .string("notify"),
                        "message": .string("MCP servers need attention:\n  slack: needs sign-in\n  foreign: needs sign-in\nRun /mcp to fix."),
                    ]),
                    .object([
                        "type": .string("tool_execution_end"), "toolCallId": .string("c"), "toolName": .string("mcp__gmail__search"),
                        "isError": .bool(true), "result": .object(["content": .array([.object([
                            "type": .string("text"),
                            "text": .string(#"MCP server "gmail" requires sign-in. Run /login mcp-example.cloud.databricks.com to sign in."#),
                        ])])]),
                    ]),
                ] + end
            }
            let pi = TestPiRuntime { options in
                options.mode == .chat
                    ? chatTransport
                    : TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "gpt-test")]))
            }
            let chat = try PiChatService(
                runtime: pi.service,
                historyStore: Self.history(),
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: {
                    let workspace = AgentMCPProvider(workspaceURL: URL(string: "https://example.cloud.databricks.com")!)
                    return AgentMCPSettings(providers: [workspace], servers: [
                        AgentMCPServer(id: .v7(), name: "slack", providerID: workspace.id, service: "system.ai.slack"),
                        AgentMCPServer(id: .v7(), name: "gmail", providerID: workspace.id, service: "system.ai.gmail"),
                    ])
                }
            )
            let thread = try await chat.startThread(model: "openai/gpt-test", effort: "medium")
            _ = await chat.acquireThreadLease(threadID: thread.id)

            func turn() async throws -> [CodexChatTurnEvent] {
                let handle = try await chat.beginTurn(
                    threadID: thread.id, inputs: [.text("Hi")], model: "openai/gpt-test", effort: "medium",
                    approvalMethod: .autoReview
                )
                var events: [CodexChatTurnEvent] = []
                for try await event in handle.events {
                    events.append(event)
                }
                return events
            }
            let first = try await turn()
            // `foreign` is not registered with this chat, so it is never reported.
            #expect(first.contains(.mcpSignInRequired(servers: ["slack"])))
            #expect(first.contains(.mcpSignInRequired(servers: ["gmail", "slack"])))
            // The same process keeps both disconnected, so the next turn reports them right after it starts.
            let second = try await turn()
            // The chat clears the report at `.started`, so it must follow that event.
            let started = try #require(second.firstIndex { if case .started = $0 { true } else { false } })
            #expect(second.dropFirst(started + 1).first == .mcpSignInRequired(servers: ["gmail", "slack"]))
        }

        @Test(arguments: [CodexChatApprovalMethod.ask, .autoReview, .fullAccess])
        func approvalPreflightUsesNativeBoundsAndRejectsStoppedTurns(method: CodexChatApprovalMethod) async throws {
            let fixture = try Self.fixture { _ in }
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium")
            _ = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Update the meeting")], model: nil, effort: "medium",
                approvalMethod: method
            )
            func check(_ id: String, text: String, server: String = "dahlia") async throws -> Bool {
                await fixture.chatTransport.emit(TestPiTransport.bridgeRequest(id: id, method: "approvalCheck", payload: .object([
                    "kind": .string("mcpToolCall"), "server": .string(server), "tool": .string("update_meeting_summary"),
                    "arguments": .object(["summary": .string(text)]),
                ])))
                let response = await fixture.chatTransport.command { $0["id"]?.stringValue == id }
                let value = try #require(response["value"]?.stringValue)
                return try JSONDecoder().decode(Bool.self, from: Data(value.utf8))
            }
            #expect(try await check("small", text: "New note"))
            #expect(try await check("summary", text: String(repeating: "会議の要約\n", count: 2000)))
            #expect(try await !check("large", text: String(repeating: "a", count: CodexChatApprovalNormalizer.byteLimit)))
            #expect(try await !check("multibyte", text: String(repeating: "あ", count: CodexChatApprovalNormalizer.byteLimit / 2)))
            #expect(try await !check("unregistered", text: "New note", server: "unregistered"))
            #expect(await fixture.chat.sessions[thread.id]?.turn?.pendingApprovals.isEmpty == true)
            await fixture.chat.abort(threadID: thread.id)
            #expect(try await !check("stopped", text: "New note"))
            await fixture.chat.closeSession(thread.id)
            await fixture.pi.service.shutdown()
        }

        @Test
        func aiReviewReasonIsShownWithTheMCPCall() throws {
            let request = try #require(PiChatService.approvalRequest(id: "review", payload: .object([
                "kind": .string("mcpToolCall"), "server": .string("dahlia"),
                "tool": .string("update_meeting"), "arguments": .object(["title": .string("New title")]),
                "reason": .string("AI review requires your approval: external side effect"),
            ])))
            #expect(request.reason == "AI review requires your approval: external side effect")
            #expect(request.mcpTool == "update_meeting")
            #expect(request.canApprove)
        }

        @Test
        func approvalPayloadsAreBoundedLikeCodexApprovals() {
            let large = String(repeating: "x", count: CodexChatApprovalNormalizer.byteLimit + 1)
            let request = PiChatService.approvalRequest(id: "a", payload: .object([
                "kind": .string("mcpToolCall"), "server": .string("dahlia"), "tool": .string("update_meeting"),
                "arguments": .object(["note": .string(large)]),
            ]))
            #expect(request?.reviewability == .tooLarge)
            #expect(request?.canApprove == false)
            #expect(PiChatService.approvalRequest(id: "b", payload: .object(["kind": .string("unknown")])) == nil)
        }
    }

    private extension [CodexChatTurnEvent] {
        func itemID(_ index: Int) -> String {
            switch self[index] {
            case let .reasoningDelta(itemID, _, _), let .delta(itemID, _): itemID
            default: ""
            }
        }
    }
#endif
