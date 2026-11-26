import Foundation

/// A value snapshot only: calendar stores keep authentication, refresh, and their event projections.
struct AgentCalendarSnapshot: Sendable {
    var events: [CalendarEvent] = []
    var successfulProviders: Set<String> = []
    /// Nil means selection is unknown; failed selected providers still belong to this set.
    var selectedProviders: Set<String>?

    static func provider(for event: CalendarEvent) -> String { event.providerID ?? event.platform }

    @MainActor static func current(
        enabledSources: Set<CalendarSource> = AppSettings.enabledCalendarSources(in: .standard),
        providers: CalendarProviderCollection = .shared
    ) -> Self {
        var snapshot = Self(selectedProviders: [])
        if enabledSources.contains(.google) {
            snapshot.selectedProviders = providers.enabledIDs
            snapshot.successfulProviders = providers.successfullyLoadedProviderIDs
            snapshot.events = providers.loadedEvents.filter { snapshot.successfulProviders.contains(provider(for: $0)) }
        }
        if enabledSources.contains(.macOS) {
            snapshot.selectedProviders?.insert(CalendarEventPlatform.macOSCalendar)
            let mac = MacCalendarStore.shared
            if mac.hasFetchedEvents {
                snapshot.successfulProviders.insert(CalendarEventPlatform.macOSCalendar)
                snapshot.events += mac.loadedEvents
            }
        }
        return snapshot
    }
}
