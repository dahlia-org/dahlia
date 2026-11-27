#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import Synchronization
    import Testing
    @testable import Dahlia

    struct PiScheduleConnectionTests {
        @Test(.timeLimit(.minutes(1)))
        func gatewayReplacementRevokesRunningCallsAndTheNextScheduledLaunch() async throws {
            let provider = AgentMCPProvider(workspaceURL: URL(string: "https://one.example.com")!)
            let other = AgentMCPProvider(workspaceURL: URL(string: "https://two.example.com")!)
            let registration = AgentMCPServer(id: .v7(), name: "github", providerID: provider.id, service: "system.ai.github")
            let settings = Mutex(AgentMCPSettings(providers: [provider, other], servers: [registration]))
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
            let schedules = AgentScheduleService(dbQueue: store.dbQueue)
            let connectors = settings.withLock { $0 }
            let tool = "mcp__github__search"
            _ = try schedules.execute(
                .object(["action": .string("create"), "schedule": .string("30m"), "prompt": .string("Read repositories")]),
                account: AppAccount.key, approved: true,
                tools: AgentMCPSettings.scheduledToolGrants([tool], connections: connectors.mcpConnectionIDs, servers: connectors.scheduledServers)
            )
            let schedule = try #require(try schedules.list(account: AppAccount.key).first)
            try await store.dbQueue.write { try $0.execute(sql: "UPDATE chat_schedules SET notify=0 WHERE id=?", arguments: [schedule.id]) }
            let chat = PiChatService(
                runtime: pi.service, historyStore: store,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { settings.withLock { $0 } }, fileAccessSettings: { .init() }
            )
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            _ = try schedules.execute(.object(["action": .string("run"), "job_id": .string(schedule.id)]), account: AppAccount.key, approved: false, tools: [])
            await chat.scheduleRuns(accountID: AppAccount.key)
            let run = try #require(try await chat.attach(threadID: schedule.threadID))
            let process = try #require(await chat.sessions[schedule.threadID]?.processID)
            let payload = JSONValue.object(["name": .string(tool), "readOnly": .bool(true)])
            #expect(try await chat.learningTool("scheduledTool", payload: payload, threadID: schedule.threadID, processID: process) == .bool(true))
            let firstLaunch = try #require(pi.launches.all.first { $0.mode == .chat })
            #expect(firstLaunch.environment["DAHLIA_PI_MCP_CONFIG"]?.contains(provider.host) == true)

            settings.withLock {
                $0.servers = [.init(id: .v7(), name: "github", providerID: other.id, service: "system.ai.github")]
            }
            #expect(try await chat.learningTool("scheduledTool", payload: payload, threadID: schedule.threadID, processID: process) == .bool(false))
            let transport = try #require(transports.all.last)
            await transport.emit(TestPiTransport.settled())
            for try await _ in run.events {}

            _ = try schedules.execute(.object(["action": .string("run"), "job_id": .string(schedule.id)]), account: AppAccount.key, approved: false, tools: [])
            await chat.scheduleRuns(accountID: AppAccount.key)
            let secondTransport = await transports.transport(at: 1)
            _ = await secondTransport.command("prompt")
            let next = try #require(try await chat.attach(threadID: schedule.threadID))
            let nextLaunch = try #require(pi.launches.all.last { $0.mode == .chat })
            #expect(nextLaunch.environment["DAHLIA_PI_MCP_CONFIG"] == "{}")
            #expect(nextLaunch.environment["DAHLIA_PI_MCP_SERVERS"] == #"["dahlia"]"#)
            let nextTransport = try #require(transports.all.last)
            await nextTransport.emit(TestPiTransport.settled())
            for try await _ in next.events {}
            await chat.closeSession(schedule.threadID)
            await pi.service.shutdown()
        }

        @Test(arguments: [false, true])
        func connectorEditInvalidatesPendingScheduleApproval(gateway: Bool) async throws {
            let provider = AgentMCPProvider(workspaceURL: URL(string: "https://one.example.com")!)
            let registration = AgentMCPServer(
                id: .v7(), name: "mail", providerID: gateway ? provider.id : nil, service: "system.ai.mail",
                direct: gateway ? nil : .init(command: "first-mcp")
            )
            let settings = Mutex(AgentMCPSettings(providers: [provider], servers: [registration]))
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
                $0.servers = [AgentMCPServer(
                    id: .v7(), name: "mail", providerID: gateway ? provider.id : nil, service: "system.ai.mail",
                    direct: gateway ? nil : .init(command: "second-mcp")
                )]
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
