import Foundation
import Observation

struct DahliaAccountConnection: Identifiable, Equatable, Sendable {
    let record: DahliaAccountConnectionRecord
    let account: DahliaCloudAccount?
    let isCloud: Bool
    let vaultCount: Int
    let grantedScopes: Set<String>

    init(
        record: DahliaAccountConnectionRecord,
        account: DahliaCloudAccount?,
        isCloud: Bool,
        vaultCount: Int = 0,
        grantedScopes: Set<String> = []
    ) {
        self.record = record
        self.account = account
        self.isCloud = isCloud
        self.vaultCount = vaultCount
        self.grantedScopes = grantedScopes
    }

    var id: UUID { record.id }
    var origin: String { record.origin }
    var isSignedIn: Bool { account != nil }
    var supportsArtifactExport: Bool {
        grantedScopes.contains(DahliaArtifactExportService.requiredScope)
            || grantedScopes.contains("files")
    }

    var displayName: String { account?.displayName ?? origin }
}

@MainActor
@Observable
final class DahliaCloudAccountController {
    private enum AccountOperation: Equatable {
        case signingIn
        case reauthenticating(UUID)
        case signingOut(UUID)
        case removing(UUID)
    }

    typealias ServiceFactory = @Sendable (UUID, DahliaCloudConfiguration) -> DahliaCloudService

    static let shared = DahliaCloudAccountController()

    private(set) var connections: [DahliaAccountConnection] = []
    private(set) var errorMessage: String?
    private var activeOperation: AccountOperation?

    let defaultConfiguration: DahliaCloudConfiguration?
    private let serviceFactory: ServiceFactory
    private let codexHomeLocator: ApplicationSupportCodexHomeLocator
    private var services: [UUID: DahliaCloudService] = [:]
    private var repository: MeetingRepository?
    private weak var appDatabase: AppDatabaseManager?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var operationGeneration = 0
    @ObservationIgnored private var completedSignInConnectionID: UUID?

    init(
        configuration: DahliaCloudConfiguration? = .current,
        serviceFactory: ServiceFactory? = nil,
        codexHomeLocator: ApplicationSupportCodexHomeLocator = ApplicationSupportCodexHomeLocator()
    ) {
        defaultConfiguration = configuration
        self.codexHomeLocator = codexHomeLocator
        self.serviceFactory = serviceFactory ?? { id, configuration in
            DahliaCloudService(
                configuration: configuration,
                storage: .keychain(connectionID: id)
            )
        }
    }

    var isSigningIn: Bool {
        switch activeOperation {
        case .signingIn, .reauthenticating:
            true
        default:
            false
        }
    }

    var isBusy: Bool { activeOperation != nil }

    var cloudConnection: DahliaAccountConnection? {
        connections.first(where: \.isCloud)
    }

    var serverConnections: [DahliaAccountConnection] {
        connections.filter { !$0.isCloud }
    }

    func isBusy(connectionID: UUID) -> Bool {
        activeOperation == .reauthenticating(connectionID)
            || activeOperation == .signingOut(connectionID)
            || activeOperation == .removing(connectionID)
    }

    func configure(appDatabase: AppDatabaseManager?) async {
        guard self.appDatabase !== appDatabase else { return }
        self.appDatabase = appDatabase
        repository = appDatabase.map { MeetingRepository(dbQueue: $0.dbQueue) }
        services.removeAll()
        await reload()
    }

    func reload() async {
        guard let repository else {
            connections = []
            return
        }
        do {
            let records = try await repository.fetchDahliaAccountConnections()
            let vaultCounts = try await repository.vaultCountsByAccountConnectionID()
            var loadedConnections: [DahliaAccountConnection] = []
            for record in records {
                let service = try service(for: record)
                await DahliaCloudTokenServiceRegistry.shared.register(service, connectionID: record.id)
                let credential = try? await service.storedCredential()
                loadedConnections.append(DahliaAccountConnection(
                    record: record,
                    account: credential?.account,
                    isCloud: isCloudOrigin(record.origin),
                    vaultCount: vaultCounts[record.id, default: 0],
                    grantedScopes: credential?.grantedScopes ?? []
                ))
            }
            connections = loadedConnections
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func startSignIn(configuration: DahliaCloudConfiguration) -> Task<Void, Never>? {
        if let connection = connections.first(where: {
            DahliaCloudService.sameOrigin($0.origin, configuration.origin)
        }) {
            return startReauthentication(connectionID: connection.id)
        }
        guard let generation = beginOperation(.signingIn) else { return nil }
        let task = Task { [weak self] in
            guard let self else { return }
            await addConnection(configuration: configuration, generation: generation)
        }
        accountTask = task
        return task
    }

    @discardableResult
    func startReauthentication(connectionID: UUID) -> Task<Void, Never>? {
        guard let generation = beginOperation(.reauthenticating(connectionID)) else { return nil }
        let task = Task { [weak self] in
            guard let self else { return }
            await reauthenticate(connectionID: connectionID, generation: generation)
        }
        accountTask = task
        return task
    }

    @discardableResult
    func startSignOut(connectionID: UUID) -> Task<Void, Never>? {
        guard let generation = beginOperation(.signingOut(connectionID)) else { return nil }
        let task = Task { [weak self] in
            guard let self else { return }
            await signOut(connectionID: connectionID, generation: generation)
        }
        accountTask = task
        return task
    }

    @discardableResult
    func startRemove(connectionID: UUID) -> Task<Void, Never>? {
        guard let generation = beginOperation(.removing(connectionID)) else { return nil }
        let task = Task { [weak self] in
            guard let self else { return }
            await remove(connectionID: connectionID, generation: generation)
        }
        accountTask = task
        return task
    }

    func cancelAccountTask() {
        accountTask?.cancel()
    }

    func validAccessToken(for connectionID: UUID) async throws -> String {
        guard let connection = connections.first(where: { $0.id == connectionID }) else {
            throw DahliaCloudError.noCredential
        }
        return try await service(for: connection.record).validAccessToken()
    }

    func signedInConnection(matching configuration: DahliaCloudConfiguration) -> DahliaAccountConnection? {
        connections.first {
            $0.isSignedIn && DahliaCloudService.sameOrigin($0.origin, configuration.origin)
        }
    }

    func completedSignInConnection(matching configuration: DahliaCloudConfiguration) -> DahliaAccountConnection? {
        guard let completedSignInConnectionID else { return nil }
        return connections.first {
            $0.id == completedSignInConnectionID
                && $0.isSignedIn
                && DahliaCloudService.sameOrigin($0.origin, configuration.origin)
        }
    }

    func reportAccountLinkingError(_ error: any Error) {
        errorMessage = error.localizedDescription
    }

    private func addConnection(configuration: DahliaCloudConfiguration, generation: Int) async {
        defer { finishOperation(generation) }
        do {
            guard !connections.contains(where: {
                DahliaCloudService.sameOrigin($0.origin, configuration.origin)
            }) else { throw DahliaCloudError.duplicateConnection }
            guard let repository else { throw DahliaCloudError.credentialStorageFailed }
            let id = UUID.v7()
            let service = serviceFactory(id, configuration)
            let credential = try await service.authorize()
            let record = DahliaAccountConnectionRecord(
                id: id,
                origin: configuration.origin,
                clientID: configuration.clientID,
                createdAt: .now
            )
            do {
                try Task.checkCancellation()
                try await repository.insertDahliaAccountConnection(record)
                try Task.checkCancellation()
                try await service.persist(credential)
                try Task.checkCancellation()
            } catch {
                if let rollbackError = await rollbackNewConnection(
                    repository: repository,
                    id: id,
                    service: service,
                    credential: credential
                ) {
                    throw rollbackError
                }
                throw error
            }
            guard isCurrentOperation(generation) else { return }
            services[id] = service
            await DahliaCloudTokenServiceRegistry.shared.register(service, connectionID: id)
            await reload()
            guard !Task.isCancelled, isCurrentOperation(generation) else { return }
            completedSignInConnectionID = id
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentOperation(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func rollbackNewConnection(
        repository: MeetingRepository,
        id: UUID,
        service: DahliaCloudService,
        credential: DahliaCloudCredential
    ) async -> Error? {
        // The sign-in task may already be cancelled, but credential and database cleanup must still run.
        await Task { @MainActor in
            do {
                try await service.deleteLocalCredential()
                try await repository.deleteDahliaAccountConnection(id: id)
                await service.revokeIfPossible(credential)
                return nil
            } catch {
                await service.revokeIfPossible(credential)
                await reload()
                return error
            }
        }.value
    }

    private func discardIssuedCredential(
        service: DahliaCloudService,
        credential: DahliaCloudCredential
    ) async -> Error? {
        await Task { @MainActor in
            do {
                try await service.deleteLocalCredential()
                await service.revokeIfPossible(credential)
                return nil
            } catch {
                await service.revokeIfPossible(credential)
                return error
            }
        }.value
    }

    private func reauthenticate(connectionID: UUID, generation: Int) async {
        defer { finishOperation(generation) }
        do {
            guard let connection = connections.first(where: { $0.id == connectionID }) else {
                throw DahliaCloudError.notConfigured
            }
            let service = try service(for: connection.record)
            let credential = try await service.authorize()
            do {
                try Task.checkCancellation()
                try await service.persist(credential)
                try Task.checkCancellation()
            } catch {
                if let cleanupError = await discardIssuedCredential(service: service, credential: credential) {
                    throw cleanupError
                }
                throw error
            }
            guard isCurrentOperation(generation) else { return }
            try await reloadCodexAuthenticationIfActive(connectionID)
            await reload()
            guard !Task.isCancelled, isCurrentOperation(generation) else { return }
            completedSignInConnectionID = connectionID
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentOperation(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func signOut(connectionID: UUID, generation: Int) async {
        defer { finishOperation(generation) }
        do {
            guard let connection = connections.first(where: { $0.id == connectionID }) else { return }
            do {
                try await service(for: connection.record).signOut()
            } catch {
                guard isCurrentOperation(generation) else { return }
                _ = await refreshAfterSignOut(connectionID: connectionID)
                throw error
            }
            guard isCurrentOperation(generation) else { return }
            if let refreshError = await refreshAfterSignOut(connectionID: connectionID) {
                throw refreshError
            }
        } catch is CancellationError {
            guard isCurrentOperation(generation) else { return }
            return
        } catch {
            guard isCurrentOperation(generation) else { return }
            await reload()
            errorMessage = error.localizedDescription
        }
    }

    private func refreshAfterSignOut(connectionID: UUID) async -> Error? {
        await Task { @MainActor in
            var refreshError: Error?
            do {
                try await reloadCodexAuthenticationIfActive(connectionID)
            } catch {
                refreshError = error
            }
            await reload()
            return refreshError
        }.value
    }

    private func remove(connectionID: UUID, generation: Int) async {
        defer { finishOperation(generation) }
        do {
            guard let connection = connections.first(where: { $0.id == connectionID }),
                  !connection.isSignedIn,
                  let repository
            else { return }
            if VaultAISettingsModel.shared.accountConnectionID == connectionID {
                VaultAISettingsModel.shared.accountConnectionID = nil
                guard await VaultAISettingsModel.shared.waitForRuntimeContext() else {
                    throw CodexConfigurationError.accountNotReady
                }
            }
            try await service(for: connection.record).deleteLocalCredential()
            try await GoogleSignInAdapter.deleteDriveSession(scope: .dahlia(connectionID))
            AppSettings.shared.clearGoogleDriveExportFolder(scope: .dahlia(connectionID))
            try await repository.deleteDahliaAccountConnection(id: connectionID)
            try codexHomeLocator.removeHome(connectionID: connectionID)
            services.removeValue(forKey: connectionID)
            await DahliaCloudTokenServiceRegistry.shared.remove(connectionID: connectionID)
            guard isCurrentOperation(generation) else { return }
            await reload()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentOperation(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func service(for record: DahliaAccountConnectionRecord) throws -> DahliaCloudService {
        if let service = services[record.id] { return service }
        guard let configuration = configuration(for: record) else { throw DahliaCloudError.notConfigured }
        let service = serviceFactory(record.id, configuration)
        services[record.id] = service
        return service
    }

    private func reloadCodexAuthenticationIfActive(_ connectionID: UUID) async throws {
        guard VaultAISettingsModel.shared.accountConnectionID == connectionID else { return }
        try await CodexAppServerService.shared.reloadConfiguration()
    }

    private func configuration(for record: DahliaAccountConnectionRecord) -> DahliaCloudConfiguration? {
        DahliaCloudConfiguration.make(urlString: record.origin, clientID: record.clientID)
    }

    private func isCloudOrigin(_ origin: String) -> Bool {
        guard let defaultConfiguration else { return false }
        return DahliaCloudService.sameOrigin(defaultConfiguration.origin, origin)
    }

    private func beginOperation(_ operation: AccountOperation) -> Int? {
        guard activeOperation == nil else { return nil }
        operationGeneration += 1
        activeOperation = operation
        errorMessage = nil
        switch operation {
        case .signingIn, .reauthenticating:
            completedSignInConnectionID = nil
        default:
            break
        }
        return operationGeneration
    }

    private func isCurrentOperation(_ generation: Int) -> Bool {
        activeOperation != nil && operationGeneration == generation
    }

    private func finishOperation(_ generation: Int) {
        guard isCurrentOperation(generation) else { return }
        activeOperation = nil
        accountTask = nil
    }
}
