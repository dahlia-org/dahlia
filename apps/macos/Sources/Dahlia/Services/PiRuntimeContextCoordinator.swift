import DahliaRuntimeSupport
import Foundation
import GRDB

actor PiRuntimeContextCoordinator {
    static let shared = PiRuntimeContextCoordinator()

    private var repository: MeetingRepository?
    private let agentLocator: PiAgentDirectoryLocator
    private let databricksClient: DatabricksOAuthService
    private let service: PiRuntimeService
    private let contextStore: PiRuntimeContextStore
    private var activationGeneration = 0
    /// Whether this coordinator wrote the configuration the store reports.
    private var hasConfigured = false

    init(
        agentLocator: PiAgentDirectoryLocator = PiAgentDirectoryLocator(),
        databricksClient: DatabricksOAuthService = .shared,
        service: PiRuntimeService = .shared,
        contextStore: PiRuntimeContextStore = .shared
    ) {
        self.agentLocator = agentLocator
        self.databricksClient = databricksClient
        self.service = service
        self.contextStore = contextStore
    }

    func configure(dbQueue: any DatabaseWriter) {
        repository = MeetingRepository(dbQueue: dbQueue)
    }

    /// Writes Pi's configuration for the app's account once; later calls return at once.
    func activate() async throws {
        guard !contextStore.isConfigured || !hasConfigured else { return }
        activationGeneration += 1
        let generation = activationGeneration
        contextStore.beginActivation()
        do {
            try await service.reloadConfiguration(applyingContext: {
                try await self.configure(generation: generation)
            }, interruptActiveOperations: true)
        } catch {
            if generation == activationGeneration { contextStore.activationFailed() }
            throw error
        }
    }

    /// Writes the providers again after a provider account was added or removed. Pi reads them when it starts: each new
    /// process has them, and chats reopen with them as their turns end (`PiChatService`), so no running work stops.
    func providerAccountsDidChange() async throws {
        guard hasConfigured else { return }
        activationGeneration += 1
        let generation = activationGeneration
        contextStore.beginActivation()
        do {
            try await service.reloadConfiguration(applyingContext: {
                try await self.configure(generation: generation)
            })
        } catch {
            if generation == activationGeneration { contextStore.activationFailed() }
            throw error
        }
        await PiChatService.shared.providerAccountsDidChange()
    }

    private func configure(generation: Int) async throws {
        try Task.checkCancellation()
        guard generation == activationGeneration else { throw CancellationError() }

        let agentURL = try agentLocator.agentURL()
        // Subscriptions use Pi's built-in catalog, and workspaces added in Agents settings keep their entries, so only
        // the provider accounts the app holds the credential for are written.
        let accounts = ProviderAccountDirectory.accounts
        var providers: [String: JSONValue] = [:]
        for account in accounts {
            try await providers.merge(piProviders(for: account, agentURL: agentURL)) { $1 }
        }
        // A removed connection's provider goes, so Pi stops offering its models; a workspace added before keeps its own.
        let kept = Set(PiProviderConfiguration.bridgedProviderIDs).union(AgentMCPSettings.load().providers.map(\.id))
        try Task.checkCancellation()
        guard generation == activationGeneration else { throw CancellationError() }
        try PiProviderConfiguration.updateProviders(agentURL: agentURL) { recorded in
            recorded = recorded.filter { id, _ in
                kept.contains(id) || !(PiProviderConfiguration.isAddedWorkspace(id) || id == PiProviderConfiguration.legacyDatabricksProviderID
                    || id == "dahlia")
            }
            recorded.merge(providers) { $1 }
        }
        hasConfigured = true
        try Task.checkCancellation()
        guard generation == activationGeneration else { throw CancellationError() }
        contextStore.apply(providers: accounts, dahliaBaseURL: PiProviderConfiguration.dahliaBaseURL(agentURL: agentURL))
    }

    /// One provider account's entries in `models.json`; empty keeps them as recorded.
    private func piProviders(
        for account: ProviderAccount,
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
            // The routes are paths; the connection's provider gets them on its workspace's host, with the models turned
            // on in Agents settings, from the gateway's saved list (the bundled one before it first answers).
            let connection = try await databricksClient.connection(id: connectionID)
            let workspaceURL = try databricksClient.normalizedWorkspaceURL(connection.host)
            let providerID = AgentMCPProvider.id(for: workspaceURL)
            return try PiProviderConfiguration.databricksProviders(
                PiProviderConfiguration.databricksModels(
                    workspaceURL: workspaceURL,
                    services: PiProviderConfiguration.gatewayServices(agentURL: agentURL)[providerID],
                    providerID: providerID,
                    isProviderAccount: true
                ),
                choices: AgentModelSettings.choices(),
                workspaceURL: workspaceURL,
                providerID: providerID
            )
        }
    }
}
