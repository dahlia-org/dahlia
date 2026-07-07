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

        #expect(provider.requestAccessCallCount == 1)
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

        #expect(store.state == .loaded)
        #expect(store.availableCalendars == [primaryCalendar, secondaryCalendar])
        #expect(store.selectedCalendarIDs == [primaryCalendar.id, secondaryCalendar.id])
        #expect(store.upcomingEvents == [fixtureEvent])
        #expect(provider.fetchEventsCallCount == 1)
        #expect(provider.requestedCalendars == [primaryCalendar, secondaryCalendar])
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

        #expect(store.state == .needsCalendarSelection)
        #expect(store.selectedCalendarIDs.isEmpty)
        #expect(store.upcomingEvents.isEmpty)
        #expect(provider.fetchEventsCallCount == 0)
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
            meetingURL: nil
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
            meetingURL: nil
        )

        let filtered = EventKitMacCalendarEventStore.sortAndFilter(
            [later, outsideWindow, earlier],
            now: fixtureNow,
            intervalEnd: intervalEnd
        )

        #expect(filtered == [earlier, later])
    }

    @Test
    func meetingURLExtractorFindsKnownMeetingLinksInNotes() {
        let url = CalendarMeetingURLExtractor.meetingURL(
            url: URL(string: "https://example.com/not-a-meeting"),
            textFields: ["Join from https://teams.microsoft.com/l/meetup-join/abc."]
        )

        #expect(url?.absoluteString == "https://teams.microsoft.com/l/meetup-join/abc")
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
    meetingURL: URL(string: "https://meet.google.com/test-link")
)

@MainActor
private final class MockMacCalendarEventStore: MacCalendarEventStoreProviding {
    var authorizationStatus: MacCalendarAuthorizationStatus
    var requestAccessResult: Result<Bool, Error>
    var calendarsResult: Result<[CalendarListItem], Error>
    var eventsResult: Result<[CalendarEvent], Error>
    private(set) var requestAccessCallCount = 0
    private(set) var fetchEventsCallCount = 0
    private(set) var requestedCalendars: [CalendarListItem] = []

    init(
        authorizationStatus: MacCalendarAuthorizationStatus,
        requestAccessResult: Result<Bool, Error> = .success(true),
        calendars: [CalendarListItem] = [],
        events: [CalendarEvent] = []
    ) {
        self.authorizationStatus = authorizationStatus
        self.requestAccessResult = requestAccessResult
        self.calendarsResult = .success(calendars)
        self.eventsResult = .success(events)
    }

    func requestFullAccessToEvents() async throws -> Bool {
        requestAccessCallCount += 1
        let granted = try requestAccessResult.get()
        authorizationStatus = granted ? .fullAccess : .denied
        return granted
    }

    func fetchCalendarList() throws -> [CalendarListItem] {
        try calendarsResult.get()
    }

    func fetchUpcomingEvents(calendars: [CalendarListItem], now _: Date, daysAhead _: Int) throws -> [CalendarEvent] {
        fetchEventsCallCount += 1
        requestedCalendars = calendars
        return try eventsResult.get()
    }
}

private func isolatedUserDefaults() -> UserDefaults {
    let suiteName = "MacCalendarStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
#endif
