import DahliaRuntimeSupport
import Foundation
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct PiChatServiceTests {
        private struct Fixture {
            let pi: TestPiRuntime
            let chat: PiChatService
            let chatTransport: TestPiTransport
        }

        /// The chat process answers every command and runs `onPrompt` for user prompts.
        private static func fixture(
            commands: JSONValue? = nil,
            delaysCommands: Bool = false,
            promptNotifications: [JSONValue] = [],
            promptDisposition: String = "started",
            onPrompt: @escaping @Sendable (TestPiTransport) async -> Void
        ) -> Fixture {
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
            let chat = PiChatService(
                runtime: pi.service,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                reviewModel: { _ in "reviewer/test-model" },
                mcpSettings: { _ in AgentMCPSettings() },
                fileAccessSettings: { _ in PiFileAccessSettings() }
            )
            Task {
                // A user prompt starts the scripted turn; extension commands start with "/".
                let prompt = await chatTransport.command {
                    $0["type"]?.stringValue == "prompt" && $0["message"]?.stringValue?.hasPrefix("/") == false
                }
                guard !prompt.isEmpty else { return }
                await onPrompt(chatTransport)
            }
            return Fixture(pi: pi, chat: chat, chatTransport: chatTransport)
        }

        @Test(arguments: ["info", "warning", "error", "unknown"])
        func handledMCPCommandPreservesNotificationsBeforeFinishingWithoutAnAgentRun(notifyType: String) async throws {
            let fixture = Self.fixture(promptNotifications: [
                .object([
                    "type": .string("extension_ui_request"),
                    "id": .string("status"),
                    "method": .string("notify"),
                    "notifyType": .string(notifyType),
                    "message": .string("dahlia: connected\n12 tools"),
                ]),
            ], promptDisposition: "handled") { _ in }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium", workspaceID: .v7())
            let turn = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("/mcp")], model: nil, effort: "medium", approvalMethod: .ask, expectedProvider: nil
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
        func commandDiscoveryUsesChatResourcesWithoutCreatingAThreadOrPrompt() async throws {
            let fixture = Self.fixture(commands: .array([
                .object(["name": .string("skill:summary"), "source": .string("skill"), "description": .string("Summarize")]),
                .object(["name": .string("mcp"), "source": .string("extension")]),
            ])) { _ in }
            let commands = try await fixture.chat.commands(threadID: nil, workspaceID: .v7())
            #expect(commands.map(\.name) == ["mcp", "skill:summary"])
            let launch = try #require(fixture.pi.launches.all.first { $0.mode == .chat })
            #expect(launch.arguments.contains("--no-session"))
            #expect(launch.arguments.contains("--skill"))
            #expect(launch.arguments.contains("builtin:mcp"))
            #expect(await fixture.chatTransport.isClosed)
            #expect(await fixture.chatTransport.commands.allSatisfy { $0["type"]?.stringValue == "get_commands" })
        }

        @Test
        func malformedCommandDiscoveryStillClosesItsTemporaryProcess() async throws {
            let fixture = Self.fixture(commands: .array([.object(["name": .string("missing-source")])])) { _ in }
            await #expect(throws: (any Error).self) {
                try await fixture.chat.commands(threadID: nil, workspaceID: .v7())
            }
            #expect(await fixture.chatTransport.isClosed)
        }

        @Test
        func cancellingCommandDiscoveryClosesItsTemporaryProcess() async throws {
            let fixture = Self.fixture(delaysCommands: true) { _ in }
            let task = Task { try await fixture.chat.commands(threadID: nil, workspaceID: .v7()) }
            _ = await fixture.chatTransport.command("get_commands")
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(await fixture.chatTransport.isClosed)
        }

        @Test
        func commandDiscoveryReusesTheOpenThreadWithoutClosingIt() async throws {
            let fixture = Self.fixture(commands: .array([])) { transport in
                await transport.emit(TestPiTransport.assistantEnd("Done"))
                await transport.emit(TestPiTransport.settled())
            }
            let workspaceID = UUID.v7()
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium", workspaceID: workspaceID)
            let lease = await fixture.chat.acquireThreadLease(threadID: thread.id)
            let turn = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("Hello")], model: nil, effort: "medium",
                approvalMethod: .ask, expectedProvider: nil
            )
            for try await _ in turn.events {}
            #expect(try await fixture.chat.commands(threadID: thread.id, workspaceID: workspaceID).isEmpty)
            #expect(fixture.pi.launches.all.filter { $0.mode == .chat }.count == 1)
            #expect(await !fixture.chatTransport.isClosed)
            await fixture.chat.releaseThreadLease(threadID: thread.id, leaseID: lease)
        }

        @Test
        func deniedToolReportsActivityAndTheTurnStillCompletes() async throws {
            let fixture = Self.fixture { transport in
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
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium", workspaceID: .v7())
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("inspect agent")], model: nil, effort: "medium",
                approvalMethod: .ask, expectedProvider: nil
            )
            var events: [CodexChatTurnEvent] = []
            for try await event in handle.events {
                events.append(event)
            }
            #expect(events.contains(.toolActivity(.init(name: "bash", status: .running))))
            #expect(events.contains(.toolActivity(.init(name: "bash", status: .inaccessible))))
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
            #expect(PiChatService.toolActivity(event) == .init(name: "read", status: expected))
            #expect(PiChatService.toolActivity(["type": .string("message_end"), "toolName": .string("read")]) == nil)
        }

        @Test
        func turnStreamsTextAndReasoningThenCompletes() async throws {
            let fixture = Self.fixture { transport in
                await transport.emit(.object(["type": .string("message_update"), "assistantMessageEvent": .object([
                    "type": .string("thinking_delta"), "delta": .string("think"),
                ])]))
                await transport.emit(.object(["type": .string("message_update"), "assistantMessageEvent": .object([
                    "type": .string("text_delta"), "delta": .string("Hel"),
                ])]))
                await transport.emit(TestPiTransport.assistantEnd("Hello"))
                await transport.emit(TestPiTransport.settled())
            }
            let thread = try await fixture.chat.startThread(model: "openai/gpt-test", effort: "medium", workspaceID: .v7())
            _ = await fixture.chat.acquireThreadLease(threadID: thread.id)

            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("<context>\n</context>"), .text("Hi")],
                model: "openai/gpt-test",
                effort: "high",
                approvalMethod: .autoReview,
                expectedProvider: .local
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
            #expect(launch.arguments.contains("read,ls,write,edit,bash,mcp__dahlia__*"))
            let work = fixture.pi.rootURL.appending(path: "work")
            #expect(launch.cwd == work)
            #expect(launch.arguments.contains("builtin:mcp"))
            #expect(launch.environment["DAHLIA_PI_MCP_COMMAND"]?.contains("--workspace-id") == true)
            // Commands and file tools run under Seatbelt, confined to the working folder.
            #expect(launch.fileAccess.grants.isEmpty)
            #expect(launch.environment["DAHLIA_PI_MCP_SERVERS"] == #"["dahlia"]"#)
            // The Local Account has no gateway MCPs; its mcp.json lists none.
            let mcpJSON = try PiAgentDirectoryLocator(applicationSupportURL: fixture.pi.rootURL)
                .agentURL(for: .local).appending(path: "mcp.json")
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
            let chat = PiChatService(
                runtime: pi.service,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { _ in AgentMCPSettings() },
                fileAccessSettings: { _ in permissions.withLock { $0 } }
            )
            let workspaceID = UUID.v7()
            let thread = try await chat.startThread(model: "openai/gpt-test", effort: "medium", workspaceID: workspaceID)
            let lease = await chat.acquireThreadLease(threadID: thread.id)
            let readOnly = PiFileAccessSettings(grants: [.init(path: "/private/tmp/desk-config.toml", isDirectory: false)])
            var readWrite = readOnly
            readWrite.grants[0].access = .readWrite
            for (index, configuration) in [PiFileAccessSettings(), readOnly, readWrite, PiFileAccessSettings()].enumerated() {
                permissions.withLock { $0 = configuration }
                let handle = try await chat.beginTurn(
                    threadID: thread.id, inputs: [.text("Hi")], model: nil, effort: "medium", approvalMethod: .ask, expectedProvider: .local
                )
                let process = await transports.transport(at: index)
                let launch = try #require(pi.launches.all.last { $0.mode == .chat })
                #expect(launch.fileAccess == configuration)
                #expect(launch.arguments.contains { $0.contains("desk-config.toml") } == !configuration.grants.isEmpty)
                if index == 0 {
                    // Saving a grant does not interrupt a running turn or its command discovery.
                    permissions.withLock { $0 = readOnly }
                    #expect(try await chat.commands(threadID: thread.id, workspaceID: workspaceID).isEmpty)
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
            let chat = PiChatService(
                runtime: pi.service,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { _ in AgentMCPSettings() },
                fileAccessSettings: { _ in PiFileAccessSettings() }
            )
            let thread = try await chat.startThread(model: "openai/gpt-test", effort: "medium", workspaceID: .v7())
            _ = await chat.acquireThreadLease(threadID: thread.id)

            let handle = try await chat.beginTurn(
                threadID: thread.id,
                inputs: [.text("Hi")],
                model: "openai/gpt-new",
                effort: "medium",
                approvalMethod: .autoReview,
                expectedProvider: .local
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
            let fixture = Self.fixture { transport in
                await transport.emit(TestPiTransport.bridgeRequest(id: "ui-7", method: "approval", payload: .object([
                    "kind": .string("commandExecution"), "command": .string("ls"), "cwd": .string("/tmp"),
                ])))
                _ = await transport.command("extension_ui_response")
                await transport.emit(TestPiTransport.assistantEnd("done"))
                await transport.emit(TestPiTransport.settled())
            }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium", workspaceID: .v7())

            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("run ls")], model: nil, effort: "medium",
                approvalMethod: .ask, expectedProvider: nil
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
        func approvalModeChangedDuringATurnAppliesToTheNextToolCall() async throws {
            let fixture = Self.fixture { _ in }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium", workspaceID: .v7())
            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("/dahlia-approval autoReview")], model: nil, effort: "medium",
                approvalMethod: .ask, expectedProvider: nil
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
            let fixture = Self.fixture { transport in
                await transport.emit(TestPiTransport.bridgeRequest(id: "ui-8", method: "approval", payload: .object([
                    "kind": .string("fileChange"), "path": .string("/tmp/a.txt"), "change": .string("add"), "diff": .string("+a"),
                ])))
                _ = await transport.command("abort")
                await transport.emit(TestPiTransport.settled(aborted: true))
            }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium", workspaceID: .v7())

            let handle = try await fixture.chat.beginTurn(
                threadID: thread.id, inputs: [.text("write")], model: nil, effort: "medium",
                approvalMethod: .ask, expectedProvider: nil
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
            let fixture = Self.fixture { _ in }
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium", workspaceID: .v7())
            await #expect(throws: CodexAppServerError.rpcError(code: nil, message: "no active turn to steer")) {
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
            let chat = PiChatService(
                runtime: pi.service,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true")
            )
            let thread = try await chat.startThread(model: nil, effort: "medium", workspaceID: .v7())
            _ = await chat.acquireThreadLease(threadID: thread.id)

            let stopped = Task {
                try await chat.beginTurn(
                    threadID: thread.id, inputs: [.text("hi")], model: nil, effort: "medium",
                    approvalMethod: .ask, expectedProvider: nil
                )
            }
            let first = await log.transport(at: 0)
            _ = await first.command("prompt")
            stopped.cancel()
            _ = try? await stopped.value

            #expect(await first.isClosed)
            let next = try await chat.beginTurn(
                threadID: thread.id, inputs: [.text("again")], model: nil, effort: "medium",
                approvalMethod: .ask, expectedProvider: nil
            )
            for try await _ in next.events {}
            #expect(log.all.count == 2)
        }

        @Test
        func turnReopensTheThreadAfterItsPiProcessExits() async throws {
            let log = TestPiTransportLog()
            let account = CodexRuntimeProvider.databricks(connectionID: UUID())
            let pi = TestPiRuntime(provider: account) { options in
                let transport = options.mode == .chat
                    ? TestPiTransport { command in
                        guard let id = command["id"] else { return [] }
                        let started = TestPiTransport.response(id: id, data: .object(["disposition": .string("started")]))
                        let isUserPrompt = command["type"]?.stringValue == "prompt"
                            && command["message"]?.stringValue?.hasPrefix("/") == false
                        return isUserPrompt ? [started, TestPiTransport.assistantEnd("again"), TestPiTransport.settled()] : [started]
                    }
                    : TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "databricks", id: "gpt-test")]))
                if options.mode == .chat { log.append(transport) }
                return transport
            }
            let workspaceID = UUID.v7()
            let registered = Mutex(AgentMCPSettings())
            let chat = PiChatService(
                runtime: pi.service,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { _ in registered.withLock { $0 } }
            )
            let thread = try await chat.startThread(model: nil, effort: "medium", workspaceID: workspaceID)
            _ = await chat.acquireThreadLease(threadID: thread.id)
            let sessions = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL)
                .sessionsURL(for: account, workspaceID: workspaceID)
            let file = sessions.appending(path: "2026-01-01T00-00-00-000Z_\(thread.id).jsonl")

            let first = try await chat.beginTurn(
                threadID: thread.id, inputs: [.text("hi")], model: nil, effort: "medium",
                approvalMethod: .autoReview, expectedProvider: nil
            )
            for try await _ in first.events {}
            // Pi writes the session file after the first reply.
            try Data(#"{"type":"session","id":"\#(thread.id)"}"#.utf8).write(to: file)
            #expect(pi.launches.all.last { $0.mode == .chat }?.arguments.contains("--session-id") == true)

            try await pi.service.reloadConfiguration(interruptActiveOperations: true)
            let handle = try await chat.beginTurn(
                threadID: thread.id, inputs: [.text("hello")], model: nil, effort: "medium",
                approvalMethod: .autoReview, expectedProvider: nil
            )
            var last: CodexChatTurnEvent?
            for try await event in handle.events {
                last = event
            }

            #expect(last == .completed(itemID: nil, text: nil))
            #expect(log.all.count == 2)
            let reopened = try #require(pi.launches.all.last { $0.mode == .chat })
            #expect(reopened.arguments.contains { $0.hasSuffix("/" + file.lastPathComponent) })

            /// A settings change leaves the open process alone; the next process the thread starts uses the new MCPs.
            func turn(_ text: String) async throws {
                let handle = try await chat.beginTurn(
                    threadID: thread.id, inputs: [.text(text)], model: nil, effort: "medium",
                    approvalMethod: .autoReview, expectedProvider: nil
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
            #expect(withGmail.arguments.contains("read,ls,write,edit,bash,mcp__dahlia__*,mcp__gmail__*,mcp__notion__*"))
            // Dahlia's extension registers the sign-ins mcp.json names in every process; none loads the provider file on its own.
            #expect(pi.launches.all.allSatisfy { !$0.arguments.contains { $0.hasSuffix("databricks-provider.ts") } })
            #expect(withGmail.environment["DAHLIA_PI_MCP_SERVERS"] == #"["dahlia","gmail","notion"]"#)
            // The mcp.json entry names the workspace sign-in, which the extension registers from that file.
            #expect(withGmail.environment["DAHLIA_PI_MCP_PROVIDERS"] == nil)
            #expect(withGmail.arguments.contains { $0.hasSuffix("/" + file.lastPathComponent) })
            let mcpJSON = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL).agentURL(for: account).appending(path: "mcp.json")
            let written = FileManager.default.contents(atPath: mcpJSON.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(written.contains("system.ai.gmail"))
            let entries = try JSONDecoder().decode(JSONValue.self, from: Data(written.utf8)).objectValue?["mcpServers"]?.objectValue
            #expect(entries?["notion"]?
                .objectValue?["url"] == .string("https://example.cloud.databricks.com/ai-gateway/mcp-services/main.default.notion"))
            #expect(entries?["notion"]?.objectValue?["auth"]?.objectValue?["provider"] == .string(provider.id))
            #expect(written.contains(#""provider":"example.cloud.databricks.com""#))
        }

        @Test
        func restoringHistoryStartsNoProcessAndAFailedTurnSetupClosesIt() async throws {
            let fixture = Self.fixture { _ in }
            let workspaceID = UUID.v7()
            let thread = try await fixture.chat.startThread(model: nil, effort: "medium", workspaceID: workspaceID)
            await fixture.chat.setThreadName(threadID: thread.id, name: "Named early")
            let restored = try await fixture.chat.resumeThread(id: thread.id, workspaceID: workspaceID)
            #expect(restored.title == "Named early")
            #expect(!fixture.pi.launches.all.contains { $0.mode == .chat })

            await #expect(throws: CodexConfigurationError.providerChanged(L10n.dahliaAccount)) {
                _ = try await fixture.chat.beginTurn(
                    threadID: thread.id, inputs: [.text("x")], model: nil, effort: "medium",
                    approvalMethod: .ask, expectedProvider: .dahlia(connectionID: .v7())
                )
            }
            #expect(fixture.pi.launches.all.count { $0.mode == .chat } == 1)
            #expect(await fixture.chatTransport.isClosed)
            let named = await fixture.chatTransport.command("set_session_name")
            #expect(named["name"]?.stringValue == "Named early")
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
            let chat = PiChatService(
                runtime: pi.service,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true")
            )
            let thread = try await chat.startThread(model: nil, effort: "medium", workspaceID: .v7())
            let lease = await chat.acquireThreadLease(threadID: thread.id)
            let turn = Task {
                try await chat.beginTurn(
                    threadID: thread.id, inputs: [.text("hi")], model: nil, effort: "high",
                    approvalMethod: .autoReview, expectedProvider: nil
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
        func restoredThreadsKeepNoReasoningAsNone() throws {
            let url = FileManager.default.temporaryDirectory.appending(path: "dahlia-pi-off-\(UUID().uuidString)_thread-off.jsonl")
            defer { try? FileManager.default.removeItem(at: url) }
            try Data([
                #"{"type":"session","id":"thread-off"}"#,
                #"{"type":"thinking_level_change","id":"b","thinkingLevel":"off"}"#,
            ].joined(separator: "\n").utf8).write(to: url)

            #expect(try PiChatSessionFiles.thread(at: url).reasoningEffort == "none")
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
        func sessionFilesListNewestFirstAndRestoreMessages() throws {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-pi-sessions-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
            let records: [String] = [
                #"{"type":"session","version":3,"id":"thread-1","cwd":"/w"}"#,
                #"{"type":"model_change","id":"a","provider":"openai","modelId":"gpt-test"}"#,
                #"{"type":"thinking_level_change","id":"b","thinkingLevel":"high"}"#,
                #"{"type":"message","id":"u1","message":{"role":"user","content":[{"type":"text","text":"最初の質問\n詳細"},{"type":"image","data":"\#(png)","mimeType":"image/png"}]}}"#,
                #"{"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"考え中"},{"type":"toolCall","id":"t"}]}}"#,
                #"{"type":"message","id":"a2","message":{"role":"assistant","content":[{"type":"text","text":"答え"}]}}"#,
            ]
            let old = directory.appending(path: "2026-01-01T00-00-00-000Z_thread-0.jsonl")
            try Data(#"{"type":"session","id":"thread-0"}"#.utf8).write(to: old)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
            let url = directory.appending(path: "2026-01-02T00-00-00-000Z_thread-1.jsonl")
            try Data(records.joined(separator: "\n").utf8).write(to: url)

            let page = try PiChatSessionFiles.page(in: directory, cursor: nil, limit: 1)
            #expect(page.threads.map(\.id) == ["thread-1"])
            #expect(page.threads.first?.title == "最初の質問")
            // thread-1 becoming newer after page 1 must not repeat it or skip thread-0 on page 2.
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            let second = try PiChatSessionFiles.page(in: directory, cursor: page.nextCursor, limit: 1)
            #expect(second.threads.map(\.id) == ["thread-0"])
            #expect(second.nextCursor == nil)
            #expect(PiChatSessionFiles.file(id: "thread-1", in: directory)?.lastPathComponent == url.lastPathComponent)

            let thread = try PiChatSessionFiles.thread(at: url)
            #expect(thread.model == "openai/gpt-test")
            #expect(thread.reasoningEffort == "high")
            #expect(thread.messages.map(\.role) == [.user, .assistant])
            #expect(thread.messages.first?.images.count == 1)
            #expect(thread.messages.last?.text == "答え")
            #expect(thread.messages.last?.reasoning == "考え中")
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
            let chat = PiChatService(
                runtime: pi.service,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { _ in
                    let workspace = AgentMCPProvider(workspaceURL: URL(string: "https://example.cloud.databricks.com")!)
                    return AgentMCPSettings(providers: [workspace], servers: [
                        AgentMCPServer(id: .v7(), name: "slack", providerID: workspace.id, service: "system.ai.slack"),
                        AgentMCPServer(id: .v7(), name: "gmail", providerID: workspace.id, service: "system.ai.gmail"),
                    ])
                }
            )
            let thread = try await chat.startThread(model: "openai/gpt-test", effort: "medium", workspaceID: .v7())
            _ = await chat.acquireThreadLease(threadID: thread.id)

            func turn() async throws -> [CodexChatTurnEvent] {
                let handle = try await chat.beginTurn(
                    threadID: thread.id, inputs: [.text("Hi")], model: "openai/gpt-test", effort: "medium",
                    approvalMethod: .autoReview, expectedProvider: .local
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
