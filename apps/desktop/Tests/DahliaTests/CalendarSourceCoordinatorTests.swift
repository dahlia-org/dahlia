import Combine
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CalendarSourceCoordinatorTests {
        @Test
        func refreshesOnlyEnabledSourcesAndAggregatesTheirEvents() async {
            let googleEvent = event(id: "google", platform: CalendarEventPlatform.googleCalendar, icalUid: "shared")
            let macEvent = event(id: "mac", platform: CalendarEventPlatform.macOSCalendar)
            let duplicateMacEvent = event(id: "mac-duplicate", platform: CalendarEventPlatform.macOSCalendar, icalUid: "shared")
            let googleStore = FakeCalendarEventSourceStore(source: .google, events: [googleEvent])
            let macStore = FakeCalendarEventSourceStore(source: .macOS, events: [duplicateMacEvent, macEvent])
            let coordinator = CalendarSourceCoordinator(stores: [googleStore, macStore])

            await coordinator.refreshEnabledSources([.google])

            #expect(googleStore.refreshCallCount == 1)
            #expect(macStore.refreshCallCount == 0)
            #expect(coordinator.events(for: [.google]) == [googleEvent])
            #expect(coordinator.events(for: [.google, .macOS]) == [googleEvent, macEvent])
        }

        @Test
        func updatesOnlyWhenASourcePublishesChangedEvents() {
            let originalEvent = event(id: "original", platform: CalendarEventPlatform.googleCalendar)
            let updatedEvent = event(id: "updated", platform: CalendarEventPlatform.googleCalendar)
            let store = FakeCalendarEventSourceStore(source: .google, events: [originalEvent])
            let coordinator = CalendarSourceCoordinator(stores: [store])
            var publicationCount = 0
            let cancellable = coordinator.$eventsBySource.dropFirst().sink { _ in publicationCount += 1 }

            store.replaceEvents([originalEvent])
            store.replaceEvents([updatedEvent])

            #expect(publicationCount == 1)
            #expect(coordinator.events(for: [.google]) == [updatedEvent])
            withExtendedLifetime(cancellable) {}
        }

        @Test
        func refreshesEnabledSourcesConcurrently() async {
            let blockedStore = FakeCalendarEventSourceStore(source: .google, events: [], blocksRefresh: true)
            let otherStore = FakeCalendarEventSourceStore(source: .macOS, events: [])
            let coordinator = CalendarSourceCoordinator(stores: [blockedStore, otherStore])

            let refresh = Task { await coordinator.refreshEnabledSources([.google, .macOS]) }
            await blockedStore.waitUntilRefreshStarts()
            await otherStore.waitUntilRefreshStarts()

            #expect(otherStore.refreshCallCount == 1)
            blockedStore.resumeRefresh()
            await refresh.value
        }

        @Test
        func tracksLoadedStateWithoutAnEventChange() {
            let store = FakeCalendarEventSourceStore(source: .google, events: [], isLoaded: false)
            let coordinator = CalendarSourceCoordinator(stores: [store])
            var publicationCount = 0
            let cancellable = coordinator.$loadedSources.dropFirst().sink { _ in publicationCount += 1 }

            store.setLoaded(true)

            #expect(coordinator.loadedSources == [.google])
            #expect(publicationCount == 1)
            withExtendedLifetime(cancellable) {}
        }

        private func event(id: String, platform: String, icalUid: String? = nil) -> CalendarEvent {
            CalendarEvent(
                id: id,
                calendarID: "calendar",
                calendarName: "Calendar",
                calendarColorHex: nil,
                platform: platform,
                platformId: id,
                title: id,
                description: "",
                icalUid: icalUid,
                startDate: Date(timeIntervalSince1970: 1_776_387_600),
                endDate: Date(timeIntervalSince1970: 1_776_391_200),
                isAllDay: false,
                conferenceURI: nil
            )
        }
    }

    @MainActor
    private final class FakeCalendarEventSourceStore: CalendarEventSourceStore {
        let source: CalendarSource
        @Published private(set) var upcomingEvents: [CalendarEvent]
        @Published private(set) var isLoaded: Bool
        private(set) var refreshCallCount = 0
        private let blocksRefresh: Bool
        private var refreshStartWaiter: CheckedContinuation<Void, Never>?
        private var refreshContinuation: CheckedContinuation<Void, Never>?

        var upcomingEventsPublisher: AnyPublisher<[CalendarEvent], Never> { $upcomingEvents.eraseToAnyPublisher() }
        var statePublisher: AnyPublisher<Bool, Never> { $isLoaded.eraseToAnyPublisher() }

        init(source: CalendarSource, events: [CalendarEvent], isLoaded: Bool = true, blocksRefresh: Bool = false) {
            self.source = source
            upcomingEvents = events
            self.isLoaded = isLoaded
            self.blocksRefresh = blocksRefresh
        }

        func refreshIfNeeded(force _: Bool) async {
            refreshCallCount += 1
            refreshStartWaiter?.resume()
            refreshStartWaiter = nil
            if blocksRefresh {
                await withCheckedContinuation { refreshContinuation = $0 }
            }
        }

        func replaceEvents(_ events: [CalendarEvent]) {
            guard upcomingEvents != events else { return }
            upcomingEvents = events
        }

        func setLoaded(_ isLoaded: Bool) {
            self.isLoaded = isLoaded
        }

        func waitUntilRefreshStarts() async {
            guard refreshCallCount == 0 else { return }
            await withCheckedContinuation { refreshStartWaiter = $0 }
        }

        func resumeRefresh() {
            refreshContinuation?.resume()
            refreshContinuation = nil
        }
    }
#endif
