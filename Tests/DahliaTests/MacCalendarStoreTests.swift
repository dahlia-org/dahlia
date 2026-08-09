import Combine
import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

@MainActor
struct MacCalendarStoreTests {
    @Test
    func notDeterminedStoreStartsInNotDeterminedState() {
        let store = MacCalendarStore(
            eventStoreProvider: MockMacCalendarEventStore(authorizationStatus: .notDetermined),
            userDefaults: isolatedUserDefaults(),
            storeChangedNotification: nil
        )

        #expect(store.state == .notDetermined)
        #expect(!store.isAuthorized)
    }

    @Test
    func requestAccessDeniedTransitionsToAccessDenied() async {
        let provider = MockMacCalendarEventStore(
            authorizationStatus: .notDetermined,
            requestAccessResult: .success(false)
        )
        let store = MacCalendarStore(
            eventStoreProvider: provider,
            userDefaults: isolatedUserDefaults(),
            storeChangedNotification: nil
        )

        await store.requestAccess()

        #expect(await provider.snapshot().requestAccessCallCount == 1)
        #expect(store.state == .accessDenied)
        #expect(store.availableCalendars.isEmpty)
        #expect(store.upcomingEvents.isEmpty)
    }

    @Test
    func firstAuthorizedRefreshSelectsAllCalendarsAndLoadsEvents() async {
        let defaults = isolatedUserDefaults()
        let provider = MockMacCalendarEventStore(
            authorizationStatus: .fullAccess,
            calendars: [primaryCalendar, secondaryCalendar],
            events: [fixtureEvent]
        )
        let store = MacCalendarStore(
            eventStoreProvider: provider,
            userDefaults: defaults,
            now: { fixtureNow },
            storeChangedNotification: nil
        )

        await store.refreshIfNeeded()
        let providerSnapshot = await provider.snapshot()

        #expect(store.state == .loaded)
        #expect(store.availableCalendars == [primaryCalendar, secondaryCalendar])
        #expect(store.selectedCalendarIDs == [primaryCalendar.id, secondaryCalendar.id])
        #expect(store.upcomingEvents == [fixtureEvent])
        #expect(providerSnapshot.fetchEventsCallCount == 1)
        #expect(providerSnapshot.requestedCalendars == [primaryCalendar, secondaryCalendar])
        #expect(defaults.bool(forKey: MacCalendarStore.didInitializeSelectionKey))
    }

    @Test
    func previouslyInitializedEmptySelectionRequiresCalendarSelection() async {
        let defaults = isolatedUserDefaults()
        defaults.set(true, forKey: MacCalendarStore.didInitializeSelectionKey)
        let provider = MockMacCalendarEventStore(
            authorizationStatus: .fullAccess,
            calendars: [primaryCalendar],
            events: [fixtureEvent]
        )
        let store = MacCalendarStore(
            eventStoreProvider: provider,
            userDefaults: defaults,
            now: { fixtureNow },
            storeChangedNotification: nil
        )

        await store.refreshIfNeeded()

        var publicationCount = 0
        let cancellable = store.objectWillChange.sink { publicationCount += 1 }
        await store.refreshIfNeeded()
        let providerSnapshot = await provider.snapshot()

        #expect(store.state == .needsCalendarSelection)
        #expect(store.selectedCalendarIDs.isEmpty)
        #expect(store.upcomingEvents.isEmpty)
        #expect(providerSnapshot.fetchCalendarsCallCount == 1)
        #expect(providerSnapshot.fetchEventsCallCount == 0)
        #expect(publicationCount == 0)
        withExtendedLifetime(cancellable) {}
    }

    @Test
    func setCalendarSelectionPersistsIDs() async {
        let defaults = isolatedUserDefaults()
        let provider = MockMacCalendarEventStore(
            authorizationStatus: .fullAccess,
            calendars: [primaryCalendar, secondaryCalendar],
            events: [fixtureEvent]
        )
        let store = MacCalendarStore(
            eventStoreProvider: provider,
            userDefaults: defaults,
            now: { fixtureNow },
            storeChangedNotification: nil
        )

        await store.refreshIfNeeded()
        store.setCalendarSelection([secondaryCalendar.id])

        #expect(store.selectedCalendarIDs == [secondaryCalendar.id])

        let saved = defaults.string(forKey: MacCalendarStore.selectedCalendarIDsKey)
        #expect(saved?.contains(secondaryCalendar.id) == true)
        #expect(saved?.contains(primaryCalendar.id) == false)
    }

    @Test
    func olderRefreshCannotOverwriteNewCalendarSelection() async {
        let defaults = isolatedUserDefaults()
        defaults.set(true, forKey: MacCalendarStore.didInitializeSelectionKey)
        defaults.set("[\"home\"]", forKey: MacCalendarStore.selectedCalendarIDsKey)
        let provider = OverlappingMacCalendarEventStore()
        let store = MacCalendarStore(
            eventStoreProvider: provider,
            userDefaults: defaults,
            now: { fixtureNow },
            storeChangedNotification: nil
        )

        let olderRefresh = Task { await store.refreshIfNeeded(force: true) }
        await provider.waitUntilBlockedEventFetchStarts()

        let newerRefresh = store.setCalendarSelection([secondaryCalendar.id])
        await newerRefresh?.value
        await provider.resumeBlockedEventFetch()
        await olderRefresh.value

        #expect(store.selectedCalendarIDs == [secondaryCalendar.id])
        #expect(store.upcomingEvents.map(\.calendarID) == [secondaryCalendar.id])
        #expect(store.state == .loaded)
    }

    @Test
    func cachedRefreshDoesNotInvalidateForcedRefreshInProgress() async {
        let provider = OverlappingMacCalendarEventStore(blockedFetchNumber: 2)
        let store = MacCalendarStore(
            eventStoreProvider: provider,
            userDefaults: isolatedUserDefaults(),
            now: { fixtureNow },
            storeChangedNotification: nil
        )

        await store.refreshIfNeeded(force: true)

        let forcedRefresh = Task { await store.refreshIfNeeded(force: true) }
        await provider.waitUntilBlockedEventFetchStarts()
        await store.refreshIfNeeded()
        await provider.resumeBlockedEventFetch()
        await forcedRefresh.value

        #expect(await provider.eventFetchCount() == 2)
        #expect(store.state == .loaded)
        #expect(!store.upcomingEvents.isEmpty)
    }

    @Test
    func identicalBackgroundRefreshKeepsLoadedStateAndCoalescesRequests() async {
        let provider = OverlappingMacCalendarEventStore(blockedFetchNumber: 2)
        let store = MacCalendarStore(
            eventStoreProvider: provider,
            userDefaults: isolatedUserDefaults(),
            now: { fixtureNow },
            refreshInterval: 0,
            storeChangedNotification: nil
        )
        await store.refreshIfNeeded(force: true)
        let initialEvents = store.upcomingEvents

        var eventPublicationCount = 0
        let cancellable = store.$upcomingEvents.dropFirst().sink { _ in eventPublicationCount += 1 }
        let firstRefresh = Task { await store.refreshIfNeeded() }
        await provider.waitUntilBlockedEventFetchStarts()
        let coalescedRefresh = Task { await store.refreshIfNeeded() }
        await Task.yield()

        #expect(store.state == .loaded)
        #expect(store.upcomingEvents == initialEvents)
        #expect(await provider.eventFetchCount() == 2)

        await provider.resumeBlockedEventFetch()
        await firstRefresh.value
        await coalescedRefresh.value

        #expect(eventPublicationCount == 0)
        #expect(store.state == .loaded)
        withExtendedLifetime(cancellable) {}
    }

    @Test
    func cancellingRefreshCancelsTheInFlightRequest() async {
        let provider = CancellationAwareMacCalendarEventStore(calendar: primaryCalendar, initialEvents: [fixtureEvent])
        let store = MacCalendarStore(
            eventStoreProvider: provider,
            userDefaults: isolatedUserDefaults(),
            now: { fixtureNow },
            storeChangedNotification: nil
        )
        await store.refreshIfNeeded(force: true)

        let refresh = Task { await store.refreshIfNeeded(force: true) }
        await provider.waitForFetchEventsCallCount(2)
        refresh.cancel()
        await refresh.value

        #expect(await provider.didObserveCancellation())
        #expect(store.state == .loaded)
    }

    @Test
    func retryAfterCachedRefreshFailureShowsLoading() async {
        let provider = OverlappingMacCalendarEventStore(blockedFetchNumber: 3, failedFetchNumber: 2)
        let store = MacCalendarStore(
            eventStoreProvider: provider,
            userDefaults: isolatedUserDefaults(),
            now: { fixtureNow },
            storeChangedNotification: nil
        )
        await store.refreshIfNeeded(force: true)

        await store.refreshIfNeeded(force: true)
        #expect(store.state == .failed)

        let retry = Task { await store.refreshIfNeeded(force: true) }
        await provider.waitUntilBlockedEventFetchStarts()
        #expect(store.state == .loading)
        await provider.resumeBlockedEventFetch()
        await retry.value

        #expect(store.state == .loaded)
    }

    @Test
    func sortAndFilterOrdersEventsWithinRefreshWindow() {
        let intervalEnd = Calendar.current.date(byAdding: .day, value: 7, to: fixtureNow)!
        let earlier = fixtureEvent
        let later = CalendarEvent(
            id: "work::later",
            calendarID: secondaryCalendar.id,
            calendarName: secondaryCalendar.title,
            calendarColorHex: secondaryCalendar.colorHex,
            platform: CalendarEventPlatform.macOSCalendar,
            platformId: "later",
            title: "Later meeting",
            description: "",
            icalUid: nil,
            startDate: fixtureNow.addingTimeInterval(7200),
            endDate: fixtureNow.addingTimeInterval(9000),
            isAllDay: false,
            conferenceURI: nil
        )
        let outsideWindow = CalendarEvent(
            id: "work::outside",
            calendarID: secondaryCalendar.id,
            calendarName: secondaryCalendar.title,
            calendarColorHex: secondaryCalendar.colorHex,
            platform: CalendarEventPlatform.macOSCalendar,
            platformId: "outside",
            title: "Outside window",
            description: "",
            icalUid: nil,
            startDate: fixtureNow.addingTimeInterval(9 * 24 * 60 * 60),
            endDate: fixtureNow.addingTimeInterval(9 * 24 * 60 * 60 + 3600),
            isAllDay: false,
            conferenceURI: nil
        )

        let filtered = EventKitMacCalendarEventStore.sortAndFilter(
            [later, outsideWindow, earlier],
            now: fixtureNow,
            intervalEnd: intervalEnd
        )

        #expect(filtered == [earlier, later])
    }

    @Test
    func conferenceURIExtractorFindsKnownMeetingLinksAndPrefersHTTPS() {
        let url = CalendarConferenceURIExtractor.conferenceURI(
            url: URL(string: "http://zoom.us/j/123"),
            textFields: ["Join from https://teams.microsoft.com/l/meetup-join/abc."]
        )

        #expect(url?.absoluteString == "https://teams.microsoft.com/l/meetup-join/abc")
    }

    @Test
    func allDayRecurrenceIdUsesEventKitDefaultTimeZone() throws {
        let defaultTimeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let occurrenceDate = Date(timeIntervalSince1970: 1_776_387_600)

        let recurrenceId = EventKitMacCalendarEventStore.recurrenceId(
            occurrenceDate: occurrenceDate,
            isAllDay: true,
            defaultTimeZone: defaultTimeZone
        )

        #expect(recurrenceId == "20260417")
    }
}

private let fixtureNow = Date(timeIntervalSince1970: 1_776_384_000)

private let primaryCalendar = CalendarListItem(
    id: "home",
    title: "Home",
    colorHex: "#FF9500",
    isPrimary: true
)

private let secondaryCalendar = CalendarListItem(
    id: "work",
    title: "Work",
    colorHex: "#0A84FF",
    isPrimary: false
)

private let fixtureEvent = CalendarEvent(
    id: "home::event-1",
    calendarID: primaryCalendar.id,
    calendarName: primaryCalendar.title,
    calendarColorHex: primaryCalendar.colorHex,
    platform: CalendarEventPlatform.macOSCalendar,
    platformId: "event-1",
    title: "Design review",
    description: "Review launch checklist",
    icalUid: "event-1@mac",
    startDate: fixtureNow.addingTimeInterval(3600),
    endDate: fixtureNow.addingTimeInterval(7200),
    isAllDay: false,
    conferenceURI: URL(string: "https://meet.google.com/test-link")
)

private actor MockMacCalendarEventStore: MacCalendarEventStoreProviding {
    struct Snapshot: Sendable {
        let requestAccessCallCount: Int
        let fetchCalendarsCallCount: Int
        let fetchEventsCallCount: Int
        let requestedCalendars: [CalendarListItem]
    }

    nonisolated let initialAuthorizationStatus: MacCalendarAuthorizationStatus
    private var currentAuthorizationStatus: MacCalendarAuthorizationStatus
    var requestAccessResult: Result<Bool, Error>
    var calendarsResult: Result<[CalendarListItem], Error>
    var eventsResult: Result<[CalendarEvent], Error>
    private(set) var requestAccessCallCount = 0
    private(set) var fetchCalendarsCallCount = 0
    private(set) var fetchEventsCallCount = 0
    private(set) var requestedCalendars: [CalendarListItem] = []

    init(
        authorizationStatus: MacCalendarAuthorizationStatus,
        requestAccessResult: Result<Bool, Error> = .success(true),
        calendars: [CalendarListItem] = [],
        events: [CalendarEvent] = []
    ) {
        self.initialAuthorizationStatus = authorizationStatus
        self.currentAuthorizationStatus = authorizationStatus
        self.requestAccessResult = requestAccessResult
        self.calendarsResult = .success(calendars)
        self.eventsResult = .success(events)
    }

    func authorizationStatus() -> MacCalendarAuthorizationStatus {
        currentAuthorizationStatus
    }

    func requestFullAccessToEvents() async throws -> Bool {
        requestAccessCallCount += 1
        let granted = try requestAccessResult.get()
        currentAuthorizationStatus = granted ? .fullAccess : .denied
        return granted
    }

    func fetchCalendarList() throws -> [CalendarListItem] {
        fetchCalendarsCallCount += 1
        return try calendarsResult.get()
    }

    func fetchUpcomingEvents(calendars: [CalendarListItem], now _: Date, daysAhead _: Int) throws -> [CalendarEvent] {
        fetchEventsCallCount += 1
        requestedCalendars = calendars
        return try eventsResult.get()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            requestAccessCallCount: requestAccessCallCount,
            fetchCalendarsCallCount: fetchCalendarsCallCount,
            fetchEventsCallCount: fetchEventsCallCount,
            requestedCalendars: requestedCalendars
        )
    }
}

private actor OverlappingMacCalendarEventStore: MacCalendarEventStoreProviding {
    nonisolated let initialAuthorizationStatus: MacCalendarAuthorizationStatus = .fullAccess
    private let blockedFetchNumber: Int
    private let failedFetchNumber: Int?
    private var fetchCount = 0
    private var fetchCountWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedFetchContinuation: CheckedContinuation<Void, Never>?

    init(blockedFetchNumber: Int = 1, failedFetchNumber: Int? = nil) {
        self.blockedFetchNumber = blockedFetchNumber
        self.failedFetchNumber = failedFetchNumber
    }

    func authorizationStatus() -> MacCalendarAuthorizationStatus {
        .fullAccess
    }

    func requestFullAccessToEvents() async throws -> Bool {
        true
    }

    func fetchCalendarList() async throws -> [CalendarListItem] {
        [primaryCalendar, secondaryCalendar]
    }

    func fetchUpcomingEvents(
        calendars: [CalendarListItem],
        now _: Date,
        daysAhead _: Int
    ) async throws -> [CalendarEvent] {
        fetchCount += 1
        if fetchCount == failedFetchNumber {
            throw CalendarRefreshTestError.requestFailed
        }
        if fetchCount == blockedFetchNumber {
            let waiters = fetchCountWaiters
            fetchCountWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                blockedFetchContinuation = continuation
            }
        }

        return calendars.map { calendar in
            CalendarEvent(
                id: "\(calendar.id)::event",
                calendarID: calendar.id,
                calendarName: calendar.title,
                calendarColorHex: calendar.colorHex,
                platform: CalendarEventPlatform.macOSCalendar,
                platformId: "event",
                title: calendar.title,
                description: "",
                icalUid: nil,
                startDate: fixtureNow.addingTimeInterval(3600),
                endDate: fixtureNow.addingTimeInterval(7200),
                isAllDay: false,
                conferenceURI: nil
            )
        }
    }

    func waitUntilBlockedEventFetchStarts() async {
        guard fetchCount < blockedFetchNumber else { return }
        await withCheckedContinuation { continuation in
            fetchCountWaiters.append(continuation)
        }
    }

    func resumeBlockedEventFetch() {
        blockedFetchContinuation?.resume()
        blockedFetchContinuation = nil
    }

    func eventFetchCount() -> Int {
        fetchCount
    }
}

private func isolatedUserDefaults() -> UserDefaults {
    let suiteName = "MacCalendarStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
#endif
