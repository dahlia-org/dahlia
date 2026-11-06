import DahliaRuntimeSupport
import Foundation
import GRDB

actor CodexRuntimeContextCoordinator {
    static let shared = CodexRuntimeContextCoordinator()

    private var repository: MeetingRepository?
    private let agentLocator: PiAgentDirectoryLocator
    private let databricksClient: DatabricksOAuthService
    private let service: PiRuntimeService
    private let contextStore: CodexRuntimeContextStore
    private var configuredProvider: CodexRuntimeProvider?
    private var requestedProvider: CodexRuntimeProvider?
    private var activationGeneration = 0

    init(
        agentLocator: PiAgentDirectoryLocator = PiAgentDirectoryLocator(),
        databricksClient: DatabricksOAuthService = .shared,
        service: PiRuntimeService = .shared,
        contextStore: CodexRuntimeContextStore = .shared
    ) {
        self.agentLocator = agentLocator
        self.databricksClient = databricksClient
        self.service = service
        self.contextStore = contextStore
    }

    func configure(dbQueue: DatabaseQueue) {
        repository = MeetingRepository(dbQueue: dbQueue)
    }

    func activate(_ settings: WorkspaceAISettingsSnapshot) async throws {
        try await activate(provider: CodexRuntimeProvider(
            accountConnectionID: settings.accountConnectionID,
            databricksConnectionID: settings.databricksConnectionID
        ))
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
        contextStore.beginActivation(provider)
        do {
            try await service.reloadConfiguration(applyingContext: {
                try await self.configure(provider: provider, generation: generation)
            }, interruptActiveOperations: true)
        } catch {
            if generation == activationGeneration { contextStore.activationFailed() }
            throw error
        }
    }

    private func configure(provider: CodexRuntimeProvider, generation: Int) async throws {
        try Task.checkCancellation()
        guard generation == activationGeneration else { throw CancellationError() }

        let agentURL = try agentLocator.agentURL(for: provider)
        // nil keeps the account's existing models.json.
        let providers: [String: JSONValue]?
        switch provider {
        case let .dahlia(connectionID):
            guard let record = try await repository?.fetchDahliaAccountConnection(id: connectionID),
                  let baseURL = URL(string: record.origin)?.appending(path: "api/v1")
            else { throw CodexConfigurationError.accountNotReady }
            // Activation needs no network: the catalog is fetched when models are listed (PiRuntimeService.models).
            providers = PiProviderConfiguration.dahliaBaseURL(agentURL: agentURL) == baseURL
                ? nil
                : try PiProviderConfiguration.dahliaProvider(baseURL: baseURL, catalog: .object(["data": .array([])]))
        case .local:
            // Subscriptions use Pi's built-in catalog.
            providers = [:]
        case let .databricks(connectionID):
            // The bundled routes are paths; this account's own Pi directory gets them on its workspace's host.
            let connection = try await databricksClient.connection(id: connectionID)
            providers = try PiProviderConfiguration.databricksProviders(
                workspaceURL: databricksClient.normalizedWorkspaceURL(connection.host)
            )
        }
        if let providers { try PiProviderConfiguration.write(providers, agentURL: agentURL) }
        configuredProvider = provider
        try Task.checkCancellation()
        guard generation == activationGeneration else { throw CancellationError() }
        contextStore.apply(provider)
    }
}
