import Foundation
import Network
import Observation

@MainActor
@Observable
final class ServerAccountSettingsModel {
    static let shared = ServerAccountSettingsModel()

    struct State {
        var settings: ServerAccountSettings?
        var isLoading = false
        var isSaving = false
        var isAvailable = false
        var errorMessage: String?
        var summaryMethods: [String] = []
        var summaryModels: [ServerSummaryService.Model] = []
        var modelErrorMessage: String?
        var canEdit: Bool { settings != nil && isAvailable && !isLoading && !isSaving }
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
    @ObservationIgnored private let client: SyncAPIClient
    @ObservationIgnored private let initialValues: @MainActor () -> ServerAccountSettings

    init(
        client: SyncAPIClient = SyncAPIClient(session: .shared),
        initialValues: @escaping @MainActor () -> ServerAccountSettings = { .initialValues() }
    ) {
        self.client = client
        self.initialValues = initialValues
    }

    func updateConnections(_ accounts: [DahliaAccountConnection]) {
        let next = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            account.account.map { (account.id, Connection(origin: account.origin, userID: $0.id)) }
        })
        for id in connections.keys where connections[id] != next[id] {
            tasks.removeValue(forKey: id)?.cancel()
            generations.removeValue(forKey: id)
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
                states[id]?.isSaving = false
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
    func refresh(connectionID: UUID) -> Task<Void, Never>? {
        guard isNetworkAvailable, let connection = connections[connectionID] else { return nil }
        // A notification may arrive while PATCH is in flight. Its response is the new state.
        if state(for: connectionID).isSaving { return tasks[connectionID] }
        tasks[connectionID]?.cancel()
        let generation = UUID()
        generations[connectionID] = generation
        states[connectionID, default: State()].isLoading = true
        let client = client
        let initial = initialValues()
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                var settings = try await Self.fetch(client: client, connectionID: connectionID, origin: connection.origin)
                try Task.checkCancellation()
                if settings == nil {
                    settings = try await Self.patch(
                        .init(outputLanguage: initial.outputLanguage, analysisLanguages: initial.analysisLanguages, initialize: true),
                        client: client, connectionID: connectionID, origin: connection.origin
                    )
                }
                guard let self, self.generations[connectionID] == generation, !Task.isCancelled else { return }
                let methods = await (try? ServerSummaryService(client: client).methods(connectionID: connectionID, origin: connection.origin)) ?? []
                guard self.generations[connectionID] == generation, !Task.isCancelled else { return }
                var models: [ServerSummaryService.Model] = []
                var modelError: String?
                if !methods.isEmpty {
                    do {
                        models = try await ServerSummaryService(client: client).models(connectionID: connectionID, origin: connection.origin)
                    } catch {
                        modelError = L10n.serverSummaryModelListFailed
                    }
                }
                guard self.generations[connectionID] == generation, !Task.isCancelled else { return }
                self.states[connectionID] = State(
                    settings: settings,
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

    @discardableResult
    func save(_ patch: ServerAccountSettings.Patch, connectionID: UUID) -> Task<Void, Never>? {
        guard state(for: connectionID).canEdit, let connection = connections[connectionID] else { return nil }
        tasks[connectionID]?.cancel()
        let generation = UUID()
        generations[connectionID] = generation
        states[connectionID, default: State()].isSaving = true
        let client = client
        let task = Task { [weak self] in
            do {
                let settings = try await Self.patch(patch, client: client, connectionID: connectionID, origin: connection.origin)
                guard let self, self.generations[connectionID] == generation, !Task.isCancelled else { return }
                self.states[connectionID] = State(
                    settings: settings,
                    isAvailable: true,
                    summaryMethods: self.states[connectionID]?.summaryMethods ?? [],
                    summaryModels: self.states[connectionID]?.summaryModels ?? [],
                    modelErrorMessage: self.states[connectionID]?.modelErrorMessage
                )
                self.tasks[connectionID] = nil
                // Also recover another device's update that raced the PATCH response.
                self.refresh(connectionID: connectionID)
            } catch {
                self?.failed(error, connectionID: connectionID, generation: generation)
            }
        }
        tasks[connectionID] = task
        return task
    }

    func loadedSettings(connectionID: UUID) async throws -> ServerAccountSettings {
        guard let connection = connections[connectionID] else { throw URLError(.notConnectedToInternet) }
        var pending = tasks[connectionID] ?? refresh(connectionID: connectionID)
        while let task = pending {
            await task.value
            try Task.checkCancellation()
            guard connections[connectionID] == connection else { throw URLError(.cancelled) }
            pending = tasks[connectionID]
        }
        guard let settings = state(for: connectionID).settings, state(for: connectionID).isAvailable else {
            throw URLError(.notConnectedToInternet)
        }
        return settings
    }

    private func failed(_: any Error, connectionID: UUID, generation: UUID) {
        guard generations[connectionID] == generation else { return }
        states[connectionID, default: State()].isLoading = false
        states[connectionID, default: State()].isSaving = false
        states[connectionID, default: State()].isAvailable = false
        states[connectionID, default: State()].errorMessage = L10n.serverAccountSettingsUnavailable
        tasks[connectionID] = nil
    }

    private nonisolated static func fetch(client: SyncAPIClient, connectionID: UUID, origin: String) async throws -> ServerAccountSettings? {
        let request = try request(origin: origin)
        let data = try await client.data(for: request, connectionId: connectionID, maximumBytes: 8192)
        return try JSONDecoder().decode(ServerAccountSettings.Response.self, from: data).settings
    }

    private nonisolated static func patch(
        _ patch: ServerAccountSettings.Patch, client: SyncAPIClient, connectionID: UUID, origin: String
    ) async throws -> ServerAccountSettings {
        var request = try request(origin: origin)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(patch)
        let data = try await client.data(for: request, connectionId: connectionID, maximumBytes: 8192)
        guard let settings = try JSONDecoder().decode(ServerAccountSettings.Response.self, from: data).settings else {
            throw URLError(.badServerResponse)
        }
        return settings
    }

    private nonisolated static func request(origin: String) throws -> URLRequest {
        guard let origin = URL(string: origin),
              let url = URL(string: "/api/v1/account/settings", relativeTo: origin)?.absoluteURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
