import Foundation
import Synchronization
import Testing
@testable import Dahlia

@MainActor
struct CodexRuntimeAccountIsolationTests {
    @Test(arguments: [false, true])
    func selectedProviderWaitsForActivationResult(fails: Bool) async {
        let store = CodexRuntimeContextStore()
        store.apply(.local)
        let expected = CodexRuntimeProvider.local
        store.beginActivation(expected)
        var started = false
        var finished = false
        var failure: (any Error)?
        let waiter = Task {
            started = true
            defer { finished = true }
            do {
                try await store.waitUntilActive(expected)
            } catch {
                failure = error
            }
        }
        #expect(await pollUntil { started })
        #expect(!finished)
        #expect(!store.isConfigured)
        if fails {
            store.activationFailed()
        } else {
            store.apply(expected)
        }
        let completed = await pollUntil { finished }
        waiter.cancel()
        await waiter.value
        #expect(completed)
        if fails {
            #expect(failure as? CodexConfigurationError == .accountNotReady)
        } else {
            #expect(failure == nil)
        }
    }

    @Test(arguments: ["activate", "cancel", "remove"])
    func inactiveAccountWaitHandlesReturnCancellationAndRemoval(action: String) async {
        let store = CodexRuntimeContextStore()
        store.apply(.local)
        // A summary recorded in a Databricks account waits until that account is open again.
        let expected = CodexRuntimeProvider.databricks(connectionID: .v7())
        var started = false
        var finished = false
        var failure: (any Error)?
        let waiter = Task {
            started = true
            defer { finished = true }
            do {
                try await store.waitUntilActive(expected)
            } catch {
                failure = error
            }
        }
        #expect(await pollUntil { started })
        #expect(!finished)
        switch action {
        case "activate":
            store.beginActivation(expected)
            store.apply(expected)
        case "remove":
            // Signed out: it can never come back, so the wait fails instead of hanging.
            store.accountRemoved(expected)
        default:
            waiter.cancel()
        }
        let completed = await pollUntil { finished }
        waiter.cancel()
        await waiter.value
        #expect(completed)
        switch action {
        case "activate": #expect(failure == nil)
        case "remove": #expect(failure as? CodexConfigurationError == .providerChanged(expected.displayName))
        default: #expect(failure is CancellationError)
        }
    }

    @Test
    func prepareNormalizesEffortAfterFallingBackToAnAvailableModel() async throws {
        let service = TestCodexChatService(mode: .complete)
        let settings = AppSettings()
        settings.currentWorkspace = WorkspaceRecord(
            id: .v7(),
            path: "/tmp/model-fallback",
            name: "Model Fallback",
            createdAt: .now,
            lastOpenedAt: .now
        )
        let suite = "ModelFallback-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspaceSettings = WorkspaceAISettingsModel(setupDefaults: defaults, activateRuntime: { _ in })
        try workspaceSettings.activate(workspace: #require(settings.currentWorkspace))
        workspaceSettings.chatModelID = "unavailable-model"
        workspaceSettings.chatReasoningEffort = "high"
        let session = CodexChatSessionModel(
            modelID: "unavailable-model",
            effort: "high",
            service: service,
            settings: settings,
            workspaceSettings: workspaceSettings
        )

        await session.prepare()

        #expect(session.selectedModelID == "default-model")
        #expect(session.selectedEffort == "medium")
        #expect(workspaceSettings.chatModelID == "unavailable-model")
        #expect(workspaceSettings.chatReasoningEffort == "high")

    }

    @Test
    func existingChatDoesNotSendAfterRuntimeProviderChanges() async {
        let service = TestCodexChatService(mode: .complete)
        let provider = Mutex(CodexRuntimeProvider.local)
        let settings = AppSettings()
        settings.currentWorkspace = WorkspaceRecord(
            id: .v7(),
            path: "/tmp/provider-change",
            name: "Provider Change",
            createdAt: .now,
            lastOpenedAt: .now
        )
        let session = CodexChatSessionModel(
            service: service,
            settings: settings,
            runtimeProviderResolver: { provider.withLock { $0 } }
        )
        await session.prepare()

        provider.withLock { $0 = .dahlia(connectionID: .v7()) }
        session.draft = "Do not send this"
        session.sendDraft()
        #expect(await pollUntil { session.errorMessage != nil })

        #expect(session.errorMessage == L10n.codexChatProviderChanged(L10n.localAccount))
        #expect(await service.sentTextBlocks.isEmpty)
    }

    @Test
    func databricksAccountStopsRunningLocalPiAndWritesItsGateways() async throws {
        let connection = DatabricksConnection(id: UUID(), host: "https://dbc.example.com")
        let memory = DatabricksTestStorage(connection: connection)
        let databricksClient = DatabricksOAuthService(storage: memory.storage)
        let log = TestPiTransportLog()
        let pi = TestPiRuntime { options in
            let transport = options.mode == .control
                ? TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "gpt-test")]))
                : TestPiTransport()
            log.append(transport)
            return transport
        }
        defer { try? FileManager.default.removeItem(at: pi.rootURL) }
        let locator = PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL)
        let coordinator = CodexRuntimeContextCoordinator(
            agentLocator: locator,
            databricksClient: databricksClient,
            service: pi.service,
            contextStore: pi.contextStore
        )
        let generation = Task {
            try await pi.service.generate(.init(
                model: nil,
                developerInstructions: "Summarize.",
                inputs: [.text("Transcript")],
                outputSchema: Data(#"{"type":"object"}"#.utf8)
            ))
        }
        let summary = await log.transport(at: 1)
        _ = await summary.command("prompt")

        let databricks = CodexRuntimeProvider.databricks(connectionID: connection.id)
        try await coordinator.activate(provider: databricks)

        await #expect(throws: CancellationError.self) { try await generation.value }
        #expect(await summary.isClosed)
        #expect(pi.contextStore.provider == databricks)
        // The Databricks account's own Pi directory lists its gateways; the Local Account's lists none.
        let models = try String(contentsOf: locator.agentURL(for: databricks).appending(path: "models.json"), encoding: .utf8)
        #expect(models.contains("https:\\/\\/dbc.example.com\\/ai-gateway\\/codex\\/v1") || models
            .contains("https://dbc.example.com/ai-gateway/codex/v1"))

        // The same account keeps the running configuration; the Local Account lists no gateways.
        try await coordinator.activate(provider: databricks)
        #expect(log.all.count == 2)
        try await coordinator.activate(provider: .local)
        let localModels = try String(contentsOf: locator.agentURL(for: .local).appending(path: "models.json"), encoding: .utf8)
        #expect(localModels == #"{"providers":{}}"#)
        #expect(pi.contextStore.provider == .local)
        let unavailable = CodexRuntimeProvider.dahlia(connectionID: .v7())
        await #expect(throws: CodexConfigurationError.accountNotReady) {
            try await coordinator.activate(provider: unavailable)
        }
        #expect(!pi.contextStore.isConfigured)
        try await coordinator.activate(provider: .local)
        #expect(pi.contextStore.isConfigured)
    }

    @Test
    func dahliaAccountActivatesWithoutReachingItsServer() async throws {
        let pi = TestPiRuntime { _ in TestPiTransport() }
        defer { try? FileManager.default.removeItem(at: pi.rootURL) }
        let database = try AppDatabaseManager(path: ":memory:")
        let connectionID = UUID.v7()
        try await database.dbQueue.write { db in
            try DahliaAccountConnectionRecord(
                id: connectionID, origin: "https://offline.dahlia.test", clientID: "test", createdAt: .now
            ).insert(db)
        }
        let locator = PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL)
        let coordinator = CodexRuntimeContextCoordinator(
            agentLocator: locator,
            databricksClient: DatabricksOAuthService(storage: DatabricksTestStorage(connection: nil).storage),
            service: pi.service,
            contextStore: pi.contextStore
        )
        await coordinator.configure(dbQueue: database.dbQueue)
        let modelsURL = try locator.agentURL(for: .dahlia(connectionID: connectionID)).appending(path: "models.json")

        // Activation records the Server URL without any network request; models are fetched when listed.
        try await coordinator.activate(provider: .dahlia(connectionID: connectionID))

        #expect(pi.contextStore.provider == .dahlia(connectionID: connectionID))
        let written = try String(contentsOf: modelsURL, encoding: .utf8)
        #expect(written.contains(#""models":[]"#))
        #expect(PiProviderConfiguration.dahliaBaseURL(agentURL: modelsURL.deletingLastPathComponent())?.absoluteString
            == "https://offline.dahlia.test/api/v1")
        try Data(#"{"providers":{"dahlia":{"baseUrl":"https://offline.dahlia.test/api/v1","models":[{"id":"kept"}]}}}"#.utf8)
            .write(to: modelsURL)
        try await coordinator.activate(provider: .local)
        try await coordinator.activate(provider: .dahlia(connectionID: connectionID))
        #expect(try String(contentsOf: modelsURL, encoding: .utf8).contains("kept"))
    }
}
