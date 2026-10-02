import Foundation
import Synchronization
import Testing
@testable import Dahlia

@MainActor
struct CodexRuntimeAccountIsolationTests {
    @Test(arguments: [
        (CodexRuntimeProvider.chatGPTSubscription, CodexRuntimeProvider.databricks(profile: "first")),
        (.databricks(profile: "first"), .chatGPTSubscription),
        (.databricks(profile: "first"), .databricks(profile: "second")),
    ])
    func capturedLocalProviderFailsAfterSettingsChange(expected: CodexRuntimeProvider, active: CodexRuntimeProvider) async {
        let store = CodexRuntimeContextStore()
        store.apply(active)
        var finished = false
        var failure: CodexConfigurationError?
        let waiter = Task {
            defer { finished = true }
            do {
                try await store.waitUntilActive(expected)
            } catch {
                failure = error as? CodexConfigurationError
            }
        }
        let completed = await pollUntil { finished }
        waiter.cancel()
        await waiter.value
        #expect(completed)
        #expect(failure == .providerChanged(expected.displayName))
    }

    @Test(arguments: [false, true])
    func selectedProviderWaitsForActivationResult(fails: Bool) async {
        let store = CodexRuntimeContextStore()
        store.apply(.chatGPTSubscription)
        let expected = CodexRuntimeProvider.databricks(profile: "next")
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

    @Test(arguments: ["activate", "cancel", "replace"])
    func inactiveAccountWaitHandlesReturnCancellationAndStaleSettings(action: String) async {
        let store = CodexRuntimeContextStore()
        store.apply(.dahlia(connectionID: .v7()))
        let expected = CodexRuntimeProvider.chatGPTSubscription
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
        case "cancel":
            waiter.cancel()
        default:
            store.beginActivation(.databricks(profile: "changed-while-away"))
        }
        let completed = await pollUntil { finished }
        waiter.cancel()
        await waiter.value
        #expect(completed)
        switch action {
        case "activate": #expect(failure == nil)
        case "cancel": #expect(failure is CancellationError)
        default: #expect(failure as? CodexConfigurationError == .providerChanged(expected.displayName))
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
        let provider = Mutex(CodexRuntimeProvider.chatGPTSubscription)
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

        provider.withLock { $0 = .databricks(profile: "WORK") }
        session.draft = "Do not send this"
        session.sendDraft()
        #expect(await pollUntil { session.errorMessage != nil })

        #expect(session.errorMessage == L10n.codexChatProviderChanged(L10n.chatGPTSubscription))
        #expect(await service.sentTextBlocks.isEmpty)
    }

    @Test
    func contextChangingReloadRetriesAfterCancelledReload() async throws {
        let first = TestCodexAppServerTransport(mode: .generationBlocks)
        let second = TestCodexAppServerTransport(mode: .models)
        let transports = Mutex([first, second])
        let appliedContext = Mutex(false)
        let service = makeTestCodexAppServerService(transportFactory: {
            transports.withLock { $0.removeFirst() }
        })
        let generation = Task {
            try await service.generate(.init(
                model: nil,
                developerInstructions: "Summarize.",
                inputs: [.text("Transcript")],
                outputSchema: Data(#"{"type":"object"}"#.utf8)
            ))
        }
        await service.waitUntilActiveTurnForTesting()
        let cancelledReload = Task { try await service.reloadConfiguration() }
        await service.waitUntilConfigurationReloadIsWaitingForTesting()
        let contextReload = Task {
            try await service.reloadConfiguration {
                appliedContext.withLock { $0 = true }
            }
        }

        cancelledReload.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledReload.value }
        await completeGeneration(on: first)

        _ = try await generation.value
        try await contextReload.value
        #expect(appliedContext.withLock { $0 })
        #expect(await first.isClosed)
        #expect(await !second.isClosed)
        await service.shutdown()
    }

    @Test
    func providerSwitchCancelsGenerationAndStartsNextProcessOnDemand() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "dahlia-codex-context-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
        let configurationManager = CodexConfigurationManager(homeLocator: locator)
        let connection = DatabricksConnection(id: UUID(), host: "https://dbc.example.com")
        let memory = DatabricksTestStorage(connection: connection)
        let databricksClient = DatabricksOAuthService(storage: memory.storage)
        let first = TestCodexAppServerTransport(mode: .generationBlocks)
        let second = TestCodexAppServerTransport(mode: .models)
        let transports = Mutex([first, second])
        let service = makeTestCodexAppServerService {
            transports.withLock { $0.removeFirst() }
        }
        let contextStore = CodexRuntimeContextStore()
        contextStore.apply(.chatGPTSubscription)
        let coordinator = CodexRuntimeContextCoordinator(
            configurationManager: configurationManager,
            databricksClient: databricksClient,
            service: service,
            contextStore: contextStore
        )
        let localWorkspace = WorkspaceRecord(
            id: .v7(),
            path: "/tmp/local-context",
            name: "Local",
            createdAt: .now,
            lastOpenedAt: .now
        )
        var databricksWorkspace = localWorkspace
        databricksWorkspace.id = .v7()
        databricksWorkspace.localProvider = .databricks
        databricksWorkspace.databricksProfile = connection.id.uuidString
        let generation = Task {
            try await service.generate(.init(
                model: nil,
                developerInstructions: "Summarize.",
                inputs: [.text("Transcript")],
                outputSchema: Data(#"{"type":"object"}"#.utf8)
            ))
        }
        await service.waitUntilActiveTurnForTesting()
        let databricksActivation = Task {
            try await coordinator.activate(WorkspaceAISettingsSnapshot(
                workspace: databricksWorkspace,
                localAccountSettings: .init(provider: .databricks, databricksProfile: connection.id.uuidString)
            ))
        }
        try await databricksActivation.value
        await #expect(throws: CancellationError.self) { try await generation.value }
        #expect(await first.isClosed)
        #expect(transports.withLock { $0.count } == 1)
        #expect(contextStore.provider == .databricks(profile: connection.id.uuidString))

        try await coordinator.activate(WorkspaceAISettingsSnapshot(
            workspace: localWorkspace,
            localAccountSettings: .init(provider: .chatGPTSubscription, databricksProfile: "")
        ))
        #expect(transports.withLock { $0.count } == 1)
        _ = try await service.models()
        #expect(transports.withLock { $0.count } == 0)
        try await coordinator.activate(provider: .chatGPTSubscription)
        #expect(await !second.isClosed)
        let configuration = try String(
            contentsOf: locator.homeURL().appending(path: "config.toml"),
            encoding: .utf8
        )
        #expect(configuration.contains(#"model_provider = "openai""#))
        #expect(contextStore.provider == .chatGPTSubscription)
        let unavailable = CodexRuntimeProvider.dahlia(connectionID: .v7())
        await #expect(throws: CodexConfigurationError.accountNotReady) {
            try await coordinator.activate(provider: unavailable)
        }
        #expect(!contextStore.isConfigured)
        await #expect(throws: CodexConfigurationError.accountNotReady) {
            try await contextStore.waitUntilActive(unavailable)
        }
        try await coordinator.activate(provider: .chatGPTSubscription)
        #expect(contextStore.isConfigured)
        await service.shutdown()
    }

    private func completeGeneration(on transport: TestCodexAppServerTransport) async {
        await transport.sendFromServer(.object([
            "method": .string("item/completed"),
            "params": .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "item": .object([
                    "type": .string("agentMessage"),
                    "text": .string(#"{"status":"ok"}"#),
                ]),
            ]),
        ]))
        await transport.sendFromServer(.object([
            "method": .string("turn/completed"),
            "params": .object([
                "threadId": .string("thread-1"),
                "turn": .object([
                    "id": .string("turn-1"),
                    "status": .string("completed"),
                ]),
            ]),
        ]))
    }
}
