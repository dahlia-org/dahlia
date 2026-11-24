import Combine
import DahliaRuntimeSupport
import Foundation

/// A service adapter owns one connection's authentication and replaceable event projection.
/// Other services (including Microsoft 365) can implement this without sharing Google's session or selection.
@MainActor
protocol CalendarConnectionStore: CalendarEventSourceStore {
    var state: CalendarConnectionState { get }
    var lastErrorMessage: String? { get }
    var connectionStatePublisher: AnyPublisher<CalendarConnectionState, Never> { get }
    func setActive(_ active: Bool)
}

@MainActor
final class CalendarProviderCollection: ObservableObject, CalendarEventSourceStore {
    static let shared = CalendarProviderCollection()
    static let enabledConnectionsKey = "enabledCalendarProviderConnections"

    let source: CalendarSource = .google
    @Published private(set) var connections: [CalendarProviderConnection] = []
    @Published private(set) var enabledIDs: Set<String>
    @Published private(set) var upcomingEvents: [CalendarEvent] = []
    @Published private(set) var state: CalendarConnectionState = .signedOut
    @Published private(set) var catalogError: String?
    private(set) var stores: [String: any CalendarConnectionStore] = [:]
    private var events: [String: [CalendarEvent]] = [:]
    private var states: [String: CalendarConnectionState] = [:]
    private var subscriptions: [String: Set<AnyCancellable>] = [:]
    private var observers: Set<AnyCancellable> = []
    private var catalogRevision = 0
    private var didLoadCatalog = false
    private let defaults: UserDefaults
    private let loadConnections: @MainActor () async throws -> [CalendarProviderConnection]
    private let makeStore: @MainActor (CalendarProviderConnection) -> any CalendarConnectionStore

    init(
        defaults: UserDefaults = .standard,
        observesChanges: Bool = true,
        notificationCenter: NotificationCenter = .default,
        loadConnections: @escaping @MainActor () async throws -> [CalendarProviderConnection] = CalendarProviderCollection.registeredConnections,
        makeStore: @escaping @MainActor (CalendarProviderConnection) -> any CalendarConnectionStore = CalendarProviderCollection.googleStore
    ) {
        self.defaults = defaults
        self.loadConnections = loadConnections
        self.makeStore = makeStore
        if let saved = defaults.stringArray(forKey: Self.enabledConnectionsKey) {
            enabledIDs = Set(saved)
        } else if AppSettings.enabledCalendarSources(in: defaults).contains(.google),
                  let saved = defaults.string(forKey: GoogleCalendarProvider.userDefaultsKey) {
            let id = saved.hasPrefix("google-") ? UUID(uuidString: String(saved.dropFirst(7))) : UUID(uuidString: saved)
            enabledIDs = Set(id.map { ["googleCalendar.\($0.uuidString)"] } ?? [])
            defaults.set(Array(enabledIDs).sorted(), forKey: Self.enabledConnectionsKey)
        } else {
            enabledIDs = []
        }
        if observesChanges {
            for name in [GoogleCalendarProvider.didChange, .databricksConnectionDidChange] {
                notificationCenter.publisher(for: name)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in
                        Task { await self?.reloadConnections() }
                    }.store(in: &observers)
            }
        }
    }

    func reloadConnections() async {
        catalogRevision += 1
        let revision = catalogRevision
        do {
            let catalog = try await loadConnections()
            guard revision == catalogRevision else { return }
            didLoadCatalog = true
            catalogError = nil
            let ids = Set(catalog.map(\.id))
            for id in Set(stores.keys).subtracting(ids) {
                subscriptions[id] = nil
                stores.removeValue(forKey: id)?.setActive(false)
                events[id] = nil
                states[id] = nil
            }
            enabledIDs.formIntersection(ids)
            defaults.set(Array(enabledIDs).sorted(), forKey: Self.enabledConnectionsKey)
            for connection in catalog where stores[connection.id] == nil {
                let id = connection.id
                let store = makeStore(connection)
                store.setActive(enabledIDs.contains(id))
                stores[id] = store
                events[id] = store.upcomingEvents.map { $0.scoped(to: id) }
                states[id] = store.state
                var tokens: Set<AnyCancellable> = []
                store.upcomingEventsPublisher.sink { [weak self] value in
                    self?.events[id] = value.map { $0.scoped(to: id) }
                    self?.publishSnapshot()
                }.store(in: &tokens)
                store.connectionStatePublisher.sink { [weak self] value in
                    self?.states[id] = value
                    self?.publishSnapshot()
                }.store(in: &tokens)
                subscriptions[id] = tokens
            }
            connections = catalog
            publishSnapshot()
        } catch {
            guard revision == catalogRevision else { return }
            catalogError = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let store = stores[id] else { return }
        if enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        defaults.set(Array(enabledIDs).sorted(), forKey: Self.enabledConnectionsKey)
        store.setActive(enabled)
        publishSnapshot()
        if enabled { Task { await store.refreshIfNeeded(force: false) } }
    }

    func refreshIfNeeded(force: Bool) async {
        if !didLoadCatalog { await reloadConnections() }
        await withTaskGroup(of: Void.self) { group in
            for id in enabledIDs.sorted() {
                guard let store = stores[id] else { continue }
                group.addTask { await store.refreshIfNeeded(force: force) }
            }
        }
    }

    var enabledConnections: [CalendarProviderConnection] { connections.filter { enabledIDs.contains($0.id) } }
    var isLoaded: Bool { state == .loaded }
    var hasLoadedConnection: Bool { enabledIDs.contains { states[$0] == .loaded } }
    var loadedEvents: [CalendarEvent] {
        enabledIDs.sorted().filter { states[$0] == .loaded }.flatMap { events[$0] ?? [] }.deduplicatedAcrossSources()
    }

    var lastErrorMessage: String? { enabledIDs.sorted().compactMap { stores[$0]?.lastErrorMessage }.first ?? catalogError }
    var upcomingEventsPublisher: AnyPublisher<[CalendarEvent], Never> { $upcomingEvents.eraseToAnyPublisher() }
    var statePublisher: AnyPublisher<Bool, Never> { $state.map { $0 == .loaded }.eraseToAnyPublisher() }

    private func publishSnapshot() {
        let snapshot = enabledIDs.sorted().flatMap { events[$0] ?? [] }.deduplicatedAcrossSources()
        if upcomingEvents != snapshot { upcomingEvents = snapshot }
        let enabledStates = enabledIDs.sorted().compactMap { states[$0] }
        // Healthy providers keep publishing while another connection loads or needs attention.
        state = enabledStates.first(where: \.requiresUserAttention)
            ?? (enabledStates.contains(.loading) ? .loading : enabledStates.isEmpty ? .signedOut : .loaded)
    }

    private static func registeredConnections() async throws -> [CalendarProviderConnection] {
        let databricks = try await DatabricksOAuthService.shared.connections()
        return ProviderAccountDirectory.googleConnections().map {
            CalendarProviderConnection(provider: .google(connectionID: $0.id), service: .googleCalendar, displayName: $0.displayName)
        } + databricks.map {
            CalendarProviderConnection(provider: .databricks(connectionID: $0.id), service: .googleCalendar, displayName: $0.displayName)
        }
    }

    private static func googleStore(_ connection: CalendarProviderConnection) -> any CalendarConnectionStore {
        // The catalog currently contains Google Calendar only. A future service gets its own adapter here.
        precondition(connection.service == .googleCalendar)
        let route = connection.googleRoute ?? .unassigned
        let directory = DahliaApplicationSupport.currentDirectoryURL.appending(path: "Caches/GoogleCalendar", directoryHint: .isDirectory)
        return GoogleCalendarStore(
            signInProvider: DatabricksProxyGoogleSignInProvider(provider: route), provider: route,
            initiallyActive: false, eventsCacheDirectory: directory
        )
    }
}
