import Combine
import Foundation
import Observation

@MainActor
@Observable
final class MenuBarCalendarViewModel {
    private(set) var currentDate: Date
    private(set) var agenda: MenuBarCalendarAgenda

    private let settings: AppSettings
    private let calendarSourceCoordinator: CalendarSourceCoordinator
    private var loadedSources: Set<CalendarSource>
    private var cancellables: Set<AnyCancellable> = []

    var allEnabledSourcesAreLoaded: Bool {
        CalendarSourceCoordinator.allSourcesAreLoaded(
            settings.enabledCalendarSources,
            loadedSources: loadedSources
        )
    }

    init(
        settings: AppSettings = .shared,
        calendarSourceCoordinator: CalendarSourceCoordinator = .shared
    ) {
        let now = Date.now
        self.settings = settings
        self.calendarSourceCoordinator = calendarSourceCoordinator
        self.currentDate = now
        self.loadedSources = calendarSourceCoordinator.loadedSources
        self.agenda = Self.makeAgenda(
            settings: settings,
            events: calendarSourceCoordinator.events(for: settings.enabledCalendarSources),
            now: now
        )
        observeCalendarInputs()
    }

    func runRefreshLoop() async {
        while !Task.isCancelled {
            currentDate = .now
            rebuildAgenda()
            if settings.menuBarCalendarEnabled {
                await refreshEnabledSources()
            }

            do {
                try await Task.sleep(for: refreshDelay(from: currentDate))
            } catch {
                return
            }
        }
    }

    private func observeCalendarInputs() {
        calendarSourceCoordinator.$eventsBySource
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAgendaRebuild() }
            .store(in: &cancellables)
        calendarSourceCoordinator.$loadedSources
            .dropFirst()
            .sink { [weak self] loadedSources in self?.loadedSources = loadedSources }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in self?.scheduleAgendaRebuild() }
            .store(in: &cancellables)
    }

    private func scheduleAgendaRebuild() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.rebuildAgenda()
        }
    }

    private func rebuildAgenda() {
        agenda = Self.makeAgenda(
            settings: settings,
            events: calendarSourceCoordinator.events(for: settings.enabledCalendarSources),
            now: currentDate
        )
    }

    private func refreshDelay(from now: Date) -> Duration {
        let nextMinute = Date(timeIntervalSinceReferenceDate: (floor(now.timeIntervalSinceReferenceDate / 60) + 1) * 60)
        let eventTransitions = [agenda.featuredEvent?.startDate, agenda.featuredEvent?.endDate]
            .compactMap(\.self)
            .filter { $0 > now }
        let nextUpdate = eventTransitions.min().map { min($0, nextMinute) } ?? nextMinute
        return .seconds(max(0.1, nextUpdate.timeIntervalSince(now)))
    }

    private static func makeAgenda(
        settings: AppSettings,
        events: [CalendarEvent],
        now: Date
    ) -> MenuBarCalendarAgenda {
        MenuBarCalendarAgenda(
            events: events,
            filter: settings.calendarEventFilter,
            now: now
        )
    }

    private func refreshEnabledSources() async {
        await calendarSourceCoordinator.refreshEnabledSources(settings.enabledCalendarSources)
    }
}
