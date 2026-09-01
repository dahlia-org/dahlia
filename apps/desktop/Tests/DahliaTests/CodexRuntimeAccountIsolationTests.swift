import Foundation
import Synchronization
import Testing
@testable import Dahlia

@MainActor
struct CodexRuntimeAccountIsolationTests {
    @Test
    func prepareNormalizesEffortAfterFallingBackToAnAvailableModel() async {
        let service = TestCodexChatService(mode: .complete)
        let settings = AppSettings()
        settings.currentVault = VaultRecord(
            id: .v7(),
            path: "/tmp/model-fallback",
            name: "Model Fallback",
            createdAt: .now,
            lastOpenedAt: .now
        )
        let session = CodexChatSessionModel(
            modelID: "unavailable-model",
            effort: "high",
            service: service,
            settings: settings
        )

        await session.prepare()

        #expect(session.selectedModelID == "default-model")
        #expect(session.selectedEffort == "medium")
    }

    @Test
    func existingChatDoesNotSendAfterRuntimeProviderChanges() async {
        let service = TestCodexChatService(mode: .complete)
        let provider = Mutex(CodexRuntimeProvider.chatGPTSubscription)
        let settings = AppSettings()
        settings.currentVault = VaultRecord(
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
    func cancelledProviderSwitchRestoresThePreviouslyActiveConfiguration() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "dahlia-codex-context-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
        let configurationManager = CodexConfigurationManager(homeLocator: locator)
        let profilesResponse = try JSONSerialization.data(withJSONObject: [
            "profiles": [[
                "name": "WORK",
                "host": "https://dbc.example.com",
                "auth_type": "databricks-cli",
            ]],
        ])
        let databricksClient = DatabricksCLIClient { _ in
            .init(standardOutput: profilesResponse, standardError: Data(), terminationStatus: 0)
        }
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
        let localVault = VaultRecord(
            id: .v7(),
            path: "/tmp/local-context",
            name: "Local",
            createdAt: .now,
            lastOpenedAt: .now
        )
        var databricksVault = localVault
        databricksVault.id = .v7()
        databricksVault.localProvider = .databricks
        databricksVault.databricksProfile = "WORK"
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
            try await coordinator.activate(VaultAISettingsSnapshot(vault: databricksVault))
        }
        await service.waitUntilConfigurationReloadIsWaitingForTesting()

        databricksActivation.cancel()
        await #expect(throws: CancellationError.self) { try await databricksActivation.value }
        let localActivation = Task {
            try await coordinator.activate(VaultAISettingsSnapshot(vault: localVault))
        }
        await completeGeneration(on: first)

        _ = try await generation.value
        try await localActivation.value
        let configuration = try String(
            contentsOf: locator.homeURL().appending(path: "config.toml"),
            encoding: .utf8
        )
        #expect(configuration.contains(#"model_provider = "openai""#))
        #expect(contextStore.provider == .chatGPTSubscription)
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
