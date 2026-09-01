import DahliaRuntimeSupport
import GRDB

actor CodexRuntimeContextCoordinator {
    static let shared = CodexRuntimeContextCoordinator()

    private var repository: MeetingRepository?
    private let configurationManager: CodexConfigurationManager
    private let databricksClient: DatabricksCLIClient
    private let service: CodexAppServerService
    private let contextStore: CodexRuntimeContextStore

    init(
        configurationManager: CodexConfigurationManager = CodexConfigurationManager(),
        databricksClient: DatabricksCLIClient = DatabricksCLIClient(),
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

    func activate(_ settings: VaultAISettingsSnapshot) async throws {
        let provider = CodexRuntimeProvider(
            accountConnectionID: settings.accountConnectionID,
            localProvider: settings.localProvider,
            databricksProfile: settings.databricksProfile
        )
        guard !contextStore.isConfigured || contextStore.provider != provider else { return }

        switch provider {
        case let .dahlia(connectionID):
            guard let record = try await repository?.fetchDahliaAccountConnection(id: connectionID) else {
                throw CodexConfigurationError.accountNotReady
            }
            let helperURL = try DahliaMCPBundle.executableURL()
            _ = try await configurationManager.configureDahlia(
                connectionID: connectionID,
                origin: record.origin,
                helperURL: helperURL,
                runtimeProfile: DahliaApplicationSupport.profile()
            )
        case .chatGPTSubscription:
            _ = try await configurationManager.configureChatGPTSubscription()
        case let .databricks(profileName):
            guard let profileName = profileName.nilIfBlank,
                  let profile = try await databricksClient.profiles().first(where: { $0.name == profileName })
            else { throw CodexConfigurationError.databricksProfileRequired }
            _ = try await configurationManager.configureDatabricks(profile: profile)
        }

        try await service.reloadConfiguration {
            self.contextStore.apply(provider)
        }
    }
}
