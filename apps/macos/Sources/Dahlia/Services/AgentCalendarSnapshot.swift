import Foundation

/// A value snapshot only: calendar stores keep authentication, refresh, and their event projections.
struct AgentCalendarSnapshot: Sendable {
    var events: [CalendarEvent] = []
    var successfulProviders: Set<String> = []

    static func provider(for event: CalendarEvent) -> String { event.providerID ?? event.platform }

    @MainActor static func current() -> Self {
        let enabled = AppSettings.enabledCalendarSources(in: .standard)
        var snapshot = Self()
        if enabled.contains(.google) {
            let providers = CalendarProviderCollection.shared
            snapshot.successfulProviders = providers.successfullyLoadedProviderIDs
            snapshot.events = providers.loadedEvents.filter { snapshot.successfulProviders.contains(provider(for: $0)) }
        }
        if enabled.contains(.macOS), MacCalendarStore.shared.hasFetchedEvents {
            let mac = MacCalendarStore.shared
            snapshot.successfulProviders.insert(CalendarEventPlatform.macOSCalendar)
            snapshot.events += mac.loadedEvents
        }
        return snapshot
    }
}
