#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import Synchronization
    import Testing
    @testable import Dahlia

    struct PiScheduleConnectionTests {
        @Test
        func connectorEditInvalidatesPendingScheduleApproval() async throws {
            let registration = AgentMCPServer(id: .v7(), name: "mail", providerID: nil, service: "mail", direct: .init(command: "first-mcp"))
            let settings = Mutex(AgentMCPSettings(servers: [registration]))
            let pi = TestPiRuntime { options in
                switch options.mode {
                case .chat: TestPiTransport()
                default: TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "gpt-test")]))
                }
            }
            let store = ChatThreadStore(dbQueue: try AppDatabaseManager(path: ":memory:").dbQueue)
            let chat = PiChatService(
                runtime: pi.service, historyStore: store,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { settings.withLock { $0 } }, fileAccessSettings: { .init() }
            )
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let thread = try await chat.startThread(model: nil, effort: "medium")
            _ = try await chat.beginTurn(threadID: thread.id, inputs: [.text("Schedule mail")], model: nil, effort: "medium", approvalMethod: .ask)
            let process = try #require(await chat.sessions[thread.id]?.processID)
            let prepared = try await chat.learningTool("cronjob", payload: .object([
                "action": .string("create"), "prompt": .string("Read mail"), "schedule": .string("30m"),
                "_readOnlyTools": .array([.string("mcp__mail__read")]),
            ]), threadID: thread.id, processID: process)
            let request = try #require(prepared.objectValue?["request_id"]?.stringValue)
            settings.withLock {
                $0.servers = [AgentMCPServer(id: .v7(), name: "mail", providerID: nil, service: "mail", direct: .init(command: "second-mcp"))]
            }
            await #expect(throws: (any Error).self) {
                try await chat.learningTool("cronjobCommit", payload: .object([
                    "request_id": .string(request), "approved": .bool(true),
                ]), threadID: thread.id, processID: process)
            }
            #expect(try AgentScheduleService(dbQueue: store.dbQueue).list(account: AppAccount.key).isEmpty)
            await chat.closeSession(thread.id)
            await pi.service.shutdown()
        }
    }
#endif
