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

    func configure(dbQueue: any DatabaseWriter) {
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

    // shortcut: restarting interrupts chats that use another provider; reload per provider once Pi can add one live.
    /// Writes the open account's providers again after a provider account was added or removed. Pi reads them when it
    /// starts, so its processes restart.
    func providerAccountsDidChange() async throws {
        guard contextStore.isConfigured, let provider = configuredProvider else { return }
        activationGeneration += 1
        let generation = activationGeneration
        try await service.reloadConfiguration(applyingContext: {
            try await self.configure(provider: provider, generation: generation)
        }, interruptActiveOperations: true)
    }

    private func configure(provider: CodexRuntimeProvider, generation: Int) async throws {
        try Task.checkCancellation()
        guard generation == activationGeneration else { throw CancellationError() }

        let agentURL = try agentLocator.agentURL(for: provider)
        // Subscriptions use Pi's built-in catalog, and workspaces added in Agents settings keep their entries, so only
        // the provider accounts the app holds the credential for are written.
        var providers: [String: JSONValue] = [:]
        for account in provider.providerAccounts {
            try await providers.merge(piProviders(for: account, runtime: provider, agentURL: agentURL)) { $1 }
        }
        // A removed connection's provider goes, so Pi stops offering its models.
        let removed = Set(PiProviderConfiguration.databricksProviderIDs).subtracting(provider.piBridgedProviderIDs)
        try PiProviderConfiguration.updateProviders(agentURL: agentURL) { recorded in
            recorded.merge(providers) { $1 }
            for id in removed {
                recorded.removeValue(forKey: id)
            }
        }
        configuredProvider = provider
        try Task.checkCancellation()
        guard generation == activationGeneration else { throw CancellationError() }
        contextStore.apply(provider)
    }

    /// One provider account's entries in `models.json`; empty keeps them as recorded.
    private func piProviders(
        for account: ProviderAccount,
        runtime provider: CodexRuntimeProvider,
        agentURL: URL
    ) async throws -> [String: JSONValue] {
        switch account {
        case let .dahlia(connectionID):
            guard let record = try await repository?.fetchDahliaAccountConnection(id: connectionID),
                  let baseURL = URL(string: record.origin)?.appending(path: "api/v1")
            else { throw AIConfigurationError.accountNotReady }
            // Activation needs no network: the catalog is fetched when models are listed (PiRuntimeService.models).
            return PiProviderConfiguration.dahliaBaseURL(agentURL: agentURL) == baseURL
                ? [:]
                : try PiProviderConfiguration.dahliaProvider(baseURL: baseURL, catalog: .object(["data": .array([])]))
        case let .databricks(connectionID):
            // The routes are paths; this account's own Pi directory gets them on its workspace's host, with the models
            // turned on in Agents settings, from the gateway's saved list (the bundled one before it first answers).
            let connection = try await databricksClient.connection(id: connectionID)
            let workspaceURL = try databricksClient.normalizedWorkspaceURL(connection.host)
            return try PiProviderConfiguration.databricksProviders(
                PiProviderConfiguration.databricksModels(
                    workspaceURL: workspaceURL,
                    services: PiProviderConfiguration.gatewayServices(agentURL: agentURL)[account.piProviderID]
                ),
                choices: AgentModelSettings.choices(for: provider),
                workspaceURL: workspaceURL
            )
        }
    }
}
