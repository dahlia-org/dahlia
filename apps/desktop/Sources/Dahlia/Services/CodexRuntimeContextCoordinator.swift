import DahliaRuntimeSupport
import Foundation
import GRDB

actor CodexRuntimeContextCoordinator {
    static let shared = CodexRuntimeContextCoordinator()

    private var repository: MeetingRepository?
    private let configurationManager: CodexConfigurationManager
    private let databricksClient: DatabricksOAuthService
    private let service: CodexAppServerService
    private let contextStore: CodexRuntimeContextStore
    private var configuredProvider: CodexRuntimeProvider?
    private var requestedProvider: CodexRuntimeProvider?
    private var activationGeneration = 0

    init(
        configurationManager: CodexConfigurationManager = CodexConfigurationManager(),
        databricksClient: DatabricksOAuthService = .shared,
        service: CodexAppServerService = .shared,
        contextStore: CodexRuntimeContextStore = .shared
    ) {
        self.configurationManager = configurationManager
        self.databricksClient = databricksClient
        self.service = service
        self.contextStore = contextStore
    }

    func configure(dbQueue: DatabaseQueue) {
        repository = MeetingRepository(dbQueue: dbQueue)
    }

    func activate(_ settings: WorkspaceAISettingsSnapshot) async throws {
        let provider = CodexRuntimeProvider(
            accountConnectionID: settings.accountConnectionID,
            localProvider: settings.localProvider,
            databricksProfile: settings.databricksProfile
        )
        try await activate(provider: provider)
    }

    func activate(provider: CodexRuntimeProvider) async throws {
        guard !contextStore.isConfigured
            || contextStore.provider != provider
            || configuredProvider != provider
            || requestedProvider != provider
        else { return }

        requestedProvider = provider
        activationGeneration += 1
        let generation = activationGeneration
        try await service.reloadConfiguration(applyingContext: {
            try await self.configure(provider: provider, generation: generation)
        }, interruptActiveOperations: true, startImmediately: false)
    }

    private func configure(provider: CodexRuntimeProvider, generation: Int) async throws {
        try Task.checkCancellation()
        guard generation == activationGeneration else { throw CancellationError() }

        switch provider {
        case let .dahlia(connectionID):
            guard let record = try await repository?.fetchDahliaAccountConnection(id: connectionID) else {
                throw CodexConfigurationError.accountNotReady
            }
            let helperURL = try AuthHelperBundle.executableURL()
            _ = try await configurationManager.configureDahlia(
                connectionID: connectionID,
                origin: record.origin,
                helperURL: helperURL,
                runtimeProfile: DahliaApplicationSupport.profile()
            )
        case .chatGPTSubscription:
            _ = try await configurationManager.configureChatGPTSubscription()
        case let .databricks(profileName):
            guard let id = UUID(uuidString: profileName),
                  let profile = try await databricksClient.currentConnection(), profile.id == id
            else { throw CodexConfigurationError.databricksProfileRequired }
            _ = try await configurationManager.configureDatabricks(profile: profile)
        }
        configuredProvider = provider
        try Task.checkCancellation()
        guard generation == activationGeneration else { throw CancellationError() }
        contextStore.apply(provider)
    }
}
