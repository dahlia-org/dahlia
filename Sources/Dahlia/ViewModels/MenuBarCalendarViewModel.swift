import Combine
import Foundation
import Observation

@MainActor
@Observable
final class MenuBarCalendarViewModel {
    private(set) var currentDate: Date
    private(set) var agenda: MenuBarCalendarAgenda

    private let settings: AppSettings
    private let googleCalendarStore: GoogleCalendarStore
    private let macCalendarStore: MacCalendarStore
    private var cancellables: Set<AnyCancellable> = []

    init(
        settings: AppSettings = .shared,
        googleCalendarStore: GoogleCalendarStore = .shared,
        macCalendarStore: MacCalendarStore = .shared
    ) {
        let now = Date.now
        self.settings = settings
        self.googleCalendarStore = googleCalendarStore
        self.macCalendarStore = macCalendarStore
        self.currentDate = now
        self.agenda = Self.makeAgenda(
            settings: settings,
            googleEvents: googleCalendarStore.upcomingEvents,
            macEvents: macCalendarStore.upcomingEvents,
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
        googleCalendarStore.$upcomingEvents
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAgendaRebuild() }
            .store(in: &cancellables)
        macCalendarStore.$upcomingEvents
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAgendaRebuild() }
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
            googleEvents: googleCalendarStore.upcomingEvents,
            macEvents: macCalendarStore.upcomingEvents,
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
        googleEvents: [CalendarEvent],
        macEvents: [CalendarEvent],
        now: Date
    ) -> MenuBarCalendarAgenda {
        MenuBarCalendarAgenda(
            googleEvents: googleEvents,
            macEvents: macEvents,
            enabledSources: settings.enabledCalendarSources,
            filter: settings.calendarEventFilter,
            now: now
        )
    }

    private func refreshEnabledSources() async {
        if settings.isCalendarSourceEnabled(.google) {
            await googleCalendarStore.refreshIfNeeded()
        }
        if settings.isCalendarSourceEnabled(.macOS) {
            await macCalendarStore.refreshIfNeeded()
        }
    }
}
