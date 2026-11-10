import Combine
import Foundation
import GRDB

@MainActor
protocol CalendarEventSourceStore: AnyObject, Sendable {
    var source: CalendarSource { get }
    var upcomingEvents: [CalendarEvent] { get }
    var isLoaded: Bool { get }
    var upcomingEventsPublisher: AnyPublisher<[CalendarEvent], Never> { get }
    var statePublisher: AnyPublisher<Bool, Never> { get }

    func refreshIfNeeded(force: Bool) async
}

@MainActor
final class CalendarSourceCoordinator: ObservableObject {
    static let shared = CalendarSourceCoordinator(stores: [GoogleCalendarStore.shared, MacCalendarStore.shared])

    @Published private(set) var eventsBySource: [CalendarSource: [CalendarEvent]]
    @Published private(set) var loadedSources: Set<CalendarSource>

    private let storesBySource: [CalendarSource: any CalendarEventSourceStore]
    private var cancellables: Set<AnyCancellable> = []
    private var dbQueue: DatabaseQueue?
    private var persistedSources: Set<CalendarSource> = []
    private var persistenceTask: Task<Void, Never>?

    init(stores: [any CalendarEventSourceStore], dbQueue: DatabaseQueue? = nil) {
        storesBySource = Dictionary(uniqueKeysWithValues: stores.map { ($0.source, $0) })
        eventsBySource = Dictionary(uniqueKeysWithValues: stores.map { ($0.source, $0.upcomingEvents) })
        loadedSources = Set(stores.filter(\.isLoaded).map(\.source))
        self.dbQueue = dbQueue

        for store in stores {
            store.upcomingEventsPublisher
                .sink { [weak self] events in
                    self?.updateEvents(events, for: store.source)
                }
                .store(in: &cancellables)

            store.statePublisher
                .sink { [weak self] isLoaded in
                    self?.updateLoadedState(isLoaded, for: store.source)
                }
                .store(in: &cancellables)
        }
    }

    func configure(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func refreshEnabledSources(_ enabledSources: Set<CalendarSource>, force: Bool = false) async {
        persistedSources = enabledSources
        await withTaskGroup(of: Void.self) { group in
            for source in CalendarSource.allCases where enabledSources.contains(source) {
                guard let store = storesBySource[source] else { continue }
                group.addTask {
                    await store.refreshIfNeeded(force: force)
                }
            }
        }
        schedulePersistence()
    }

    func events(for enabledSources: Set<CalendarSource>, requiringLoadedSources: Bool = false) -> [CalendarEvent] {
        CalendarSource.allCases
            .filter { enabledSources.contains($0) && (!requiringLoadedSources || loadedSources.contains($0)) }
            .flatMap { eventsBySource[$0] ?? [] }
            .deduplicatedAcrossSources()
    }

    /// Events from the enabled sources that have not ended by `now`. The stores drop ended events only when they fetch,
    /// so every upcoming list, and every check of whether one is empty, takes the caller's clock through here.
    func upcomingEvents(for enabledSources: Set<CalendarSource>, now: Date) -> [CalendarEvent] {
        events(for: enabledSources).filter { $0.endDate > now }
    }

    /// Upcoming events that pass the user's event filter, in schedule order.
    func visibleUpcomingEvents(
        for enabledSources: Set<CalendarSource>,
        filter: CalendarEventFilter,
        now: Date
    ) -> [CalendarEvent] {
        upcomingEvents(for: enabledSources, now: now)
            .filter(filter.includes)
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                if lhs.isAllDay != rhs.isAllDay {
                    return lhs.isAllDay
                }
                if lhs.endDate != rhs.endDate {
                    return lhs.endDate < rhs.endDate
                }
                if lhs.title != rhs.title {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.id < rhs.id
            }
    }

    static func allSourcesAreLoaded(
        _ enabledSources: Set<CalendarSource>,
        loadedSources: Set<CalendarSource>
    ) -> Bool {
        !enabledSources.isEmpty && enabledSources.isSubset(of: loadedSources)
    }

    private func updateEvents(_ events: [CalendarEvent], for source: CalendarSource) {
        guard eventsBySource[source] != events else { return }
        eventsBySource[source] = events
        guard persistedSources.contains(source) else { return }
        schedulePersistence()
    }

    private func schedulePersistence() {
        guard let dbQueue, !persistedSources.isEmpty else { return }
        let snapshot = CalendarSource.allCases
            .filter { persistedSources.contains($0) }
            .flatMap { eventsBySource[$0] ?? [] }
            .deduplicatedAcrossSources(mergingMissingMetadata: false)
        let previousTask = persistenceTask
        persistenceTask = Task {
            await previousTask?.value
            do {
                try await dbQueue.write { db in
                    try CalendarEventRecord.refreshLinked(events: snapshot, now: .now, in: db)
                }
            } catch {
                ErrorReportingService.capture(error, context: ["source": "calendarEventRefreshPersistence"])
            }
        }
    }

    func waitForPersistence() async {
        await persistenceTask?.value
    }

    private func updateLoadedState(_ isLoaded: Bool, for source: CalendarSource) {
        var updatedSources = loadedSources
        if isLoaded {
            updatedSources.insert(source)
        } else {
            updatedSources.remove(source)
        }
        guard updatedSources != loadedSources else {
            objectWillChange.send()
            return
        }
        loadedSources = updatedSources
    }
}

extension GoogleCalendarStore: CalendarEventSourceStore {
    var source: CalendarSource { .google }
    var isLoaded: Bool { state == .loaded }
    var upcomingEventsPublisher: AnyPublisher<[CalendarEvent], Never> { $upcomingEvents.eraseToAnyPublisher() }
    var statePublisher: AnyPublisher<Bool, Never> {
        $state.map { $0 == .loaded }.eraseToAnyPublisher()
    }
}

extension MacCalendarStore: CalendarEventSourceStore {
    var source: CalendarSource { .macOS }
    var isLoaded: Bool { state == .loaded }
    var upcomingEventsPublisher: AnyPublisher<[CalendarEvent], Never> { $upcomingEvents.eraseToAnyPublisher() }
    var statePublisher: AnyPublisher<Bool, Never> {
        $state.map { $0 == .loaded }.eraseToAnyPublisher()
    }
}
