import DahliaServerAPI
import Foundation
import Network
import Observation

@MainActor
@Observable
final class ServerAccountSettingsModel {
    static let shared = ServerAccountSettingsModel()

    struct State {
        var isLoading = false
        var isAvailable = false
        var errorMessage: String?
        var summaryMethods: [String] = []
        var summaryModels: [ServerSummaryService.Model] = []
        var modelErrorMessage: String?

        var isModelCatalogLoaded: Bool {
            isAvailable && !isLoading && errorMessage == nil && modelErrorMessage == nil
        }
    }

    private struct Connection: Equatable {
        let origin: String
        let userID: String
    }

    private(set) var states: [UUID: State] = [:]
    private(set) var isNetworkAvailable = true
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var connections: [UUID: Connection] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [UUID: UUID] = [:]
    @ObservationIgnored private var pendingModelReloads: Set<UUID> = []
    @ObservationIgnored private let client: SyncAPIClient
    init(client: SyncAPIClient = SyncAPIClient(session: .shared)) {
        self.client = client
    }

    func updateConnections(_ accounts: [DahliaAccountConnection]) {
        let next = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            account.account.map { (account.id, Connection(origin: account.origin, userID: $0.id)) }
        })
        for id in connections.keys where connections[id] != next[id] {
            tasks.removeValue(forKey: id)?.cancel()
            generations.removeValue(forKey: id)
            pendingModelReloads.remove(id)
            states.removeValue(forKey: id)
        }
        let added = next.keys.filter { connections[$0] != next[$0] }
        connections = next
        for id in added {
            refresh(connectionID: id)
        }
    }

    func state(for connectionID: UUID) -> State {
        var state = states[connectionID] ?? State()
        if !isNetworkAvailable {
            state.isAvailable = false
            state.errorMessage = L10n.serverAccountSettingsUnavailable
        }
        return state
    }

    func startNetworkMonitoring() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkAvailabilityChanged(available) }
        }
        monitor.start(queue: DispatchQueue(label: "com.dahlia.account-settings-network"))
        networkMonitor = monitor
    }

    func networkAvailabilityChanged(_ available: Bool) {
        guard available != isNetworkAvailable else { return }
        isNetworkAvailable = available
        if available {
            refreshAll()
        } else {
            for (id, task) in tasks {
                task.cancel()
                generations.removeValue(forKey: id)
                states[id]?.isLoading = false
                states[id]?.isAvailable = false
            }
            tasks.removeAll()
        }
    }

    func refreshAll() {
        for id in connections.keys {
            refresh(connectionID: id)
        }
    }

    @discardableResult
    func refresh(connectionID: UUID, reloadModels: Bool = false) -> Task<Void, Never>? {
        guard isNetworkAvailable, let connection = connections[connectionID] else { return nil }
        // Keep explicit reload intent when a notification replaces the in-flight refresh.
        if reloadModels { pendingModelReloads.insert(connectionID) }
        tasks[connectionID]?.cancel()
        let generation = UUID()
        generations[connectionID] = generation
        states[connectionID, default: State()].isLoading = true
        let client = client
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard let self, self.generations[connectionID] == generation, !Task.isCancelled else { return }
                let previous = self.state(for: connectionID)
                var methods = previous.summaryMethods
                var models = previous.summaryModels
                var modelError = previous.modelErrorMessage
                if self.pendingModelReloads.contains(connectionID) || !previous.isAvailable {
                    methods = try await ServerSummaryService(client: client).methods(connectionID: connectionID, origin: connection.origin)
                    guard self.generations[connectionID] == generation, !Task.isCancelled else { return }
                    models = []
                    modelError = nil
                    if !methods.isEmpty {
                        do {
                            models = try await ServerSummaryService(client: client).models(connectionID: connectionID, origin: connection.origin)
                        } catch {
                            modelError = L10n.serverSummaryModelListFailed
                        }
                    }
                }
                guard self.generations[connectionID] == generation, !Task.isCancelled else { return }
                self.pendingModelReloads.remove(connectionID)
                self.states[connectionID] = State(
                    isAvailable: true,
                    summaryMethods: methods,
                    summaryModels: models,
                    modelErrorMessage: modelError
                )
                self.tasks[connectionID] = nil
            } catch {
                self?.failed(error, connectionID: connectionID, generation: generation)
            }
        }
        tasks[connectionID] = task
        return task
    }

    private func failed(_: any Error, connectionID: UUID, generation: UUID) {
        guard generations[connectionID] == generation else { return }
        states[connectionID, default: State()].isLoading = false
        states[connectionID, default: State()].isAvailable = false
        states[connectionID, default: State()].errorMessage = L10n.serverAccountSettingsUnavailable
        tasks[connectionID] = nil
    }

}
