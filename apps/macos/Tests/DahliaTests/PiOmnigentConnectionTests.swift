#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import Synchronization
    import Testing
    @testable import Dahlia

    struct PiOmnigentConnectionTests {
        @Test(arguments: ["omni_create_session", "omni_list_agents", "omni_list_sessions", "omni_get_session"], [false, true])
        func changedSelectionRejectsTheOldProcessesCalls(method: String, disable: Bool) async throws {
            let first = UUID()
            let second = UUID()
            let selection = Mutex<UUID?>(first)
            let requests = Mutex<[UUID]>([])
            let transports = TestPiTransportLog()
            let pi = TestPiRuntime { options in
                if options.mode == .chat {
                    let transport = TestPiTransport()
                    transports.append(transport)
                    return transport
                }
                return TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "gpt-test")]))
            }
            let store = ChatThreadStore(dbQueue: try AppDatabaseManager(path: ":memory:").dbQueue)
            let chat = PiChatService(
                runtime: pi.service, historyStore: store,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { .init() }, fileAccessSettings: { .init() },
                omnigentConnection: { selection.withLock { $0 } }
            )
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let thread = try await chat.startThread(model: nil, effort: "medium")
            _ = await chat.acquireThreadLease(threadID: thread.id)
            let turn = try await chat.beginTurn(threadID: thread.id, inputs: [.text("Use Omnigent")], model: nil, effort: "medium", approvalMethod: .ask)
            let process = try #require(await chat.sessions[thread.id]?.processID)
            let transport = try #require(transports.all.last)
            let execute: @Sendable (String, [String: JSONValue], UUID) async throws -> JSONValue = { _, _, id in
                requests.withLock { $0.append(id) }
                return .null
            }
            let payload = JSONValue.object(["agent_id": .string("shared-agent"), "input": .string("private task")])
            _ = try await chat.omnigentTool(method, payload: payload, threadID: thread.id, processID: process, execute: execute)
            #expect(requests.withLock { $0 } == [first])

            // The tool hook can now be waiting for the user's approval. A later execution must keep its destination.
            selection.withLock { $0 = disable ? nil : second }
            await #expect(throws: PiRuntimeError.self) {
                try await chat.omnigentTool(method, payload: payload, threadID: thread.id, processID: process, execute: execute)
            }
            #expect(requests.withLock { $0 } == [first])

            await transport.emit(TestPiTransport.settled())
            for try await _ in turn.events {}
            await #expect(throws: CancellationError.self) {
                try await chat.omnigentTool(method, payload: payload, threadID: thread.id, processID: process, execute: execute)
            }
            let next = try await chat.beginTurn(threadID: thread.id, inputs: [.text("Use the new selection")], model: nil, effort: "medium", approvalMethod: .ask)
            let nextProcess = try #require(await chat.sessions[thread.id]?.processID)
            #expect(nextProcess != process)
            #expect(await chat.sessions[thread.id]?.omnigentConnectionID == (disable ? nil : second))
            let launch = try #require(pi.launches.all.last { $0.mode == .chat })
            #expect(launch.environment["DAHLIA_PI_OMNIGENT_WORKSPACE"] == (disable ? "" : second.uuidString))
            if !disable {
                _ = try await chat.omnigentTool(method, payload: payload, threadID: thread.id, processID: nextProcess, execute: execute)
                #expect(requests.withLock { $0 } == [first, second])
            }
            let nextTransport = try #require(transports.all.last)
            await nextTransport.emit(TestPiTransport.settled())
            for try await _ in next.events {}
            await chat.closeSession(thread.id)
            await pi.service.shutdown()
        }
    }
#endif
