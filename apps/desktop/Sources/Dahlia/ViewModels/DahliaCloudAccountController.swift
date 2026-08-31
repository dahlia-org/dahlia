import Foundation
import Observation

struct DahliaAccountConnection: Identifiable, Equatable, Sendable {
    let record: DahliaAccountConnectionRecord
    let account: DahliaCloudAccount?
    let isCloud: Bool

    var id: UUID { record.id }
    var origin: String { record.origin }
    var isSignedIn: Bool { account != nil }
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
    private var services: [UUID: DahliaCloudService] = [:]
    private var repository: MeetingRepository?
    private weak var appDatabase: AppDatabaseManager?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var operationGeneration = 0

    init(
        configuration: DahliaCloudConfiguration? = .current,
        serviceFactory: ServiceFactory? = nil
    ) {
        defaultConfiguration = configuration
        self.serviceFactory = serviceFactory ?? { id, configuration in
            DahliaCloudService(
                configuration: configuration,
                storage: .keychain(connectionID: id)
            )
        }
    }

    var isSigningIn: Bool { activeOperation == .signingIn }
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
            var loadedConnections: [DahliaAccountConnection] = []
            for record in records {
                let credential = try? await service(for: record).storedCredential()
                loadedConnections.append(DahliaAccountConnection(
                    record: record,
                    account: credential?.account,
                    isCloud: isCloudOrigin(record.origin)
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
            try Task.checkCancellation()
            let record = DahliaAccountConnectionRecord(
                id: id,
                origin: configuration.origin,
                clientID: configuration.clientID,
                createdAt: .now
            )
            try await repository.insertDahliaAccountConnection(record)
            do {
                try await service.persist(credential)
            } catch {
                try? await repository.deleteDahliaAccountConnection(id: id)
                throw error
            }
            guard isCurrentOperation(generation) else { return }
            services[id] = service
            await reload()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentOperation(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func reauthenticate(connectionID: UUID, generation: Int) async {
        defer { finishOperation(generation) }
        do {
            guard let connection = connections.first(where: { $0.id == connectionID }) else {
                throw DahliaCloudError.notConfigured
            }
            let service = try service(for: connection.record)
            let credential = try await service.authorize()
            try Task.checkCancellation()
            try await service.persist(credential)
            guard isCurrentOperation(generation) else { return }
            await reload()
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
            try await service(for: connection.record).signOut()
            guard isCurrentOperation(generation) else { return }
            await reload()
        } catch is CancellationError {
            guard isCurrentOperation(generation) else { return }
            await reload()
            return
        } catch {
            guard isCurrentOperation(generation) else { return }
            await reload()
            errorMessage = error.localizedDescription
        }
    }

    private func remove(connectionID: UUID, generation: Int) async {
        defer { finishOperation(generation) }
        do {
            guard let connection = connections.first(where: { $0.id == connectionID }),
                  !connection.isSignedIn,
                  let repository
            else { return }
            try await service(for: connection.record).deleteLocalCredential()
            try await repository.deleteDahliaAccountConnection(id: connectionID)
            services.removeValue(forKey: connectionID)
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
