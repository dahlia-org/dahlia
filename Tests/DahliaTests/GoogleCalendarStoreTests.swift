import AppKit
import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

@MainActor
struct GoogleCalendarStoreTests {
    @Test
    func unconfiguredStoreStartsInUnconfiguredState() {
        let store = GoogleCalendarStore(
            signInProvider: MockGoogleCalendarSignInProvider(isConfigured: false),
            apiClient: MockGoogleCalendarAPIClient(),
            userDefaults: isolatedUserDefaults()
        )

        #expect(store.state == .unconfigured)
        #expect(!store.isConfigured)
    }

    @Test
    func restorePreviousSessionLoadsCalendarsAndEvents() async throws {
        let defaults = isolatedUserDefaults()
        seedSelectedCalendars(["primary"], defaults: defaults)

        let signInProvider = MockGoogleCalendarSignInProvider(
            hasPreviousSignIn: true,
            restoreResult: .success(fixtureSession)
        )
        let apiClient = MockGoogleCalendarAPIClient(
            calendars: [primaryCalendar],
            events: [fixtureEvent]
        )
        let store = GoogleCalendarStore(
            signInProvider: signInProvider,
            apiClient: apiClient,
            userDefaults: defaults,
            now: { fixtureNow }
        )

        await store.restoreSessionIfNeeded()

        #expect(store.state == .loaded)
        #expect(store.account == fixtureSession.account)
        #expect(store.availableCalendars == [primaryCalendar])
        #expect(store.upcomingEvents == [fixtureEvent])
        #expect(apiClient.fetchEventsCallCount == 1)
    }

    @Test
    func restoreFailureMapsWebClientIDErrorToActionableMessage() async {
        let signInProvider = MockGoogleCalendarSignInProvider(
            hasPreviousSignIn: true,
            restoreResult: .failure(
                NSError(
                    domain: "GoogleSignIn",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "invalid_request: client_secret is missing."]
                )
            )
        )
        let store = GoogleCalendarStore(
            signInProvider: signInProvider,
            apiClient: MockGoogleCalendarAPIClient(),
            userDefaults: isolatedUserDefaults()
        )

        await store.restoreSessionIfNeeded()

        #expect(store.state == .failed)
        #expect(store.lastErrorMessage == L10n.googleCalendarClientSecretMissingMessage)
        #expect(store.account == nil)
    }

    @Test
    func restoreWithoutSelectedCalendarsRequiresSelection() async {
        let signInProvider = MockGoogleCalendarSignInProvider(
            hasPreviousSignIn: true,
            restoreResult: .success(fixtureSession)
        )
        let apiClient = MockGoogleCalendarAPIClient(calendars: [primaryCalendar], events: [])
        let store = GoogleCalendarStore(
            signInProvider: signInProvider,
            apiClient: apiClient,
            userDefaults: isolatedUserDefaults(),
            now: { fixtureNow }
        )

        await store.restoreSessionIfNeeded()

        #expect(store.state == .needsCalendarSelection)
        #expect(store.upcomingEvents.isEmpty)
    }

    @Test
    func disconnectClearsSelectionAndCachedData() async {
        let defaults = isolatedUserDefaults()
        seedSelectedCalendars(["primary"], defaults: defaults)

        let signInProvider = MockGoogleCalendarSignInProvider(
            hasPreviousSignIn: true,
            restoreResult: .success(fixtureSession)
        )
        let apiClient = MockGoogleCalendarAPIClient(
            calendars: [primaryCalendar],
            events: [fixtureEvent]
        )
        let store = GoogleCalendarStore(
            signInProvider: signInProvider,
            apiClient: apiClient,
            userDefaults: defaults,
            now: { fixtureNow }
        )

        await store.restoreSessionIfNeeded()
        await store.disconnect()

        #expect(signInProvider.disconnectCallCount == 1)
        #expect(store.state == .signedOut)
        #expect(store.selectedCalendarIDs.isEmpty)
        #expect(store.account == nil)
        #expect(store.availableCalendars.isEmpty)
        #expect(store.upcomingEvents.isEmpty)
    }

    @Test
    func setCalendarSelectionPersistsIDs() async {
        let defaults = isolatedUserDefaults()
        let signInProvider = MockGoogleCalendarSignInProvider(
            hasPreviousSignIn: true,
            restoreResult: .success(fixtureSession),
            refreshResult: .success(fixtureSession)
        )
        let apiClient = MockGoogleCalendarAPIClient(
            calendars: [primaryCalendar, secondaryCalendar],
            events: [fixtureEvent]
        )
        let store = GoogleCalendarStore(
            signInProvider: signInProvider,
            apiClient: apiClient,
            userDefaults: defaults,
            now: { fixtureNow }
        )

        await store.restoreSessionIfNeeded()
        store.setCalendarSelection([secondaryCalendar.id])

        #expect(store.selectedCalendarIDs == [secondaryCalendar.id])

        let saved = defaults.string(forKey: GoogleCalendarStore.selectedCalendarIDsKey)
        #expect(saved?.contains(secondaryCalendar.id) == true)
    }

    @Test
    func signInRequestsCalendarScopes() async {
        let signInProvider = MockGoogleCalendarSignInProvider(signInResult: .success(fixtureSession))
        let store = GoogleCalendarStore(
            signInProvider: signInProvider,
            apiClient: MockGoogleCalendarAPIClient(calendars: [primaryCalendar], events: []),
            userDefaults: isolatedUserDefaults(),
            now: { fixtureNow },
            presentingWindowProvider: { NSWindow() }
        )

        await store.signIn()

        #expect(signInProvider.signInRequestedScopes == [GoogleOAuthScope.calendar])
    }

    @Test
    func ignoresUnrelatedSessionChangeNotification() async {
        let watchedNotification = Notification.Name("GoogleCalendarStoreTests.watched.\(UUID().uuidString)")
        let ignoredNotification = Notification.Name("GoogleCalendarStoreTests.ignored.\(UUID().uuidString)")
        let signInProvider = MockGoogleCalendarSignInProvider(
            hasPreviousSignIn: true,
            sessionDidChangeNotification: watchedNotification,
            restoreResult: .success(fixtureSession)
        )
        let store = GoogleCalendarStore(
            signInProvider: signInProvider,
            apiClient: MockGoogleCalendarAPIClient(calendars: [primaryCalendar], events: []),
            userDefaults: isolatedUserDefaults()
        )

        NotificationCenter.default.post(name: ignoredNotification, object: nil)
        await Task.yield()

        #expect(store.state == .signedOut)
        #expect(signInProvider.restoreCallCount == 0)
    }

    @Test
    func eventTransformationPrefersConferenceEntryPointAndFiltersFutureWindow() throws {
        let conferenceItem = GoogleCalendarAPIClient.EventItem(
            id: "event-1",
            summary: "Weekly sync",
            description: "Discuss launch plan",
            iCalUID: "event-1@google.com",
            htmlLink: nil,
            hangoutLink: nil,
            start: .init(date: nil, dateTime: "2026-04-17T01:00:00Z"),
            end: .init(date: nil, dateTime: "2026-04-17T02:00:00Z"),
            originalStartTime: nil,
            conferenceData: .init(entryPoints: [
                .init(uri: "tel:+81-3-1234-5678"),
                .init(uri: "https://meet.google.com/abc-defg-hij"),
            ]),
            eventType: nil
        )
        let transformedEvent = try GoogleCalendarAPIClient.makeEvent(
            from: conferenceItem,
            calendarItem: primaryCalendar,
            calendar: .current
        )
        let event = try #require(transformedEvent)

        #expect(event.conferenceURI?.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(event.platformId == "event-1")
        #expect(event.description == "Discuss launch plan")
        #expect(event.icalUid == "event-1@google.com")
        #expect(event.recurrenceId.isEmpty)
        #expect(!event.isAllDay)

        let intervalEnd = Calendar.current.date(byAdding: .day, value: 7, to: fixtureNow)!
        let filtered = GoogleCalendarAPIClient.sortAndFilter(
            [
                event,
                GoogleCalendarEvent(
                    id: "late",
                    calendarID: primaryCalendar.id,
                    calendarName: primaryCalendar.title,
                    calendarColorHex: nil,
                    platformId: "late",
                    title: "Outside window",
                    description: "",
                    icalUid: nil,
                    startDate: Calendar.current.date(byAdding: .day, value: 9, to: fixtureNow)!,
                    endDate: Calendar.current.date(byAdding: .day, value: 9, to: fixtureNow)!,
                    isAllDay: true,
                    conferenceURI: nil
                ),
            ],
            now: fixtureNow,
            intervalEnd: intervalEnd
        )

        #expect(filtered == [event])
    }

    @Test
    func allDayEventIsAvailableForDisplayFiltering() throws {
        let allDayItem = GoogleCalendarAPIClient.EventItem(
            id: "event-2",
            summary: nil,
            description: nil,
            iCalUID: nil,
            htmlLink: nil,
            hangoutLink: nil,
            start: .init(date: "2026-04-18", dateTime: nil),
            end: .init(date: "2026-04-19", dateTime: nil),
            originalStartTime: nil,
            conferenceData: nil,
            eventType: nil
        )

        let event = try GoogleCalendarAPIClient.makeEvent(
            from: allDayItem,
            calendarItem: secondaryCalendar,
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(event?.isAllDay == true)
    }

    @Test
    func outOfOfficeEventIsAvailableForDisplayFiltering() throws {
        let outOfOfficeItem = GoogleCalendarAPIClient.EventItem(
            id: "event-3",
            summary: "Out of office",
            description: nil,
            iCalUID: nil,
            htmlLink: nil,
            hangoutLink: nil,
            start: .init(date: nil, dateTime: "2026-04-18T01:00:00Z"),
            end: .init(date: nil, dateTime: "2026-04-18T02:00:00Z"),
            originalStartTime: nil,
            conferenceData: nil,
            eventType: "outOfOffice"
        )

        let event = try GoogleCalendarAPIClient.makeEvent(
            from: outOfOfficeItem,
            calendarItem: secondaryCalendar,
            calendar: .current
        )

        #expect(event?.isOutOfOffice == true)
    }
}

#elseif canImport(XCTest)
import XCTest

@MainActor
final class GoogleCalendarStoreTests: XCTestCase {
    func testUnconfiguredStoreStartsInUnconfiguredState() {
        let store = GoogleCalendarStore(
            signInProvider: MockGoogleCalendarSignInProvider(isConfigured: false),
            apiClient: MockGoogleCalendarAPIClient(),
            userDefaults: isolatedUserDefaults()
        )

        XCTAssertEqual(store.state, .unconfigured)
        XCTAssertFalse(store.isConfigured)
    }

    func testRestorePreviousSessionLoadsCalendarsAndEvents() async throws {
        let defaults = isolatedUserDefaults()
        seedSelectedCalendars(["primary"], defaults: defaults)

        let signInProvider = MockGoogleCalendarSignInProvider(
            hasPreviousSignIn: true,
            restoreResult: .success(fixtureSession)
        )
        let apiClient = MockGoogleCalendarAPIClient(
            calendars: [primaryCalendar],
            events: [fixtureEvent]
        )
        let store = GoogleCalendarStore(
            signInProvider: signInProvider,
            apiClient: apiClient,
            userDefaults: defaults,
            now: { fixtureNow }
        )

        await store.restoreSessionIfNeeded()

        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.account, fixtureSession.account)
        XCTAssertEqual(store.availableCalendars, [primaryCalendar])
        XCTAssertEqual(store.upcomingEvents, [fixtureEvent])
        XCTAssertEqual(apiClient.fetchEventsCallCount, 1)
    }

    func testRestoreFailureMapsWebClientIDErrorToActionableMessage() async {
        let signInProvider = MockGoogleCalendarSignInProvider(
            hasPreviousSignIn: true,
            restoreResult: .failure(
                NSError(
                    domain: "GoogleSignIn",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "invalid_request: client_secret is missing."]
                )
            )
        )
        let store = GoogleCalendarStore(
            signInProvider: signInProvider,
            apiClient: MockGoogleCalendarAPIClient(),
            userDefaults: isolatedUserDefaults()
        )

        await store.restoreSessionIfNeeded()

        XCTAssertEqual(store.state, .failed)
        XCTAssertEqual(store.lastErrorMessage, L10n.googleCalendarClientSecretMissingMessage)
        XCTAssertNil(store.account)
    }
}
#endif

private let fixtureNow = Date(timeIntervalSince1970: 1_776_384_000)

private let fixtureSession = GoogleSession(
    account: GoogleCalendarAccount(
        id: "user-1",
        displayName: "Kazuki Matsuda",
        email: "kazuki@example.com"
    ),
    accessToken: "token-1",
    grantedScopes: GoogleOAuthScope.authorizationScopes(for: GoogleOAuthScope.calendar)
)

private let primaryCalendar = GoogleCalendarListItem(
    id: "primary",
    title: "Primary",
    colorHex: "#4285F4",
    isPrimary: true
)

private let secondaryCalendar = GoogleCalendarListItem(
    id: "team@example.com",
    title: "Team",
    colorHex: "#34A853",
    isPrimary: false
)

private let fixtureEvent = GoogleCalendarEvent(
    id: "primary::event-1",
    calendarID: "primary",
    calendarName: "Primary",
    calendarColorHex: "#4285F4",
    platformId: "event-1",
    title: "Design review",
    description: "Review draft",
    icalUid: "event-1@google.com",
    startDate: fixtureNow.addingTimeInterval(3600),
    endDate: fixtureNow.addingTimeInterval(7200),
    isAllDay: false,
    conferenceURI: URL(string: "https://meet.google.com/test-link")
)

@MainActor
private final class MockGoogleCalendarSignInProvider: GoogleSignInProviding {
    let isConfigured: Bool
    let hasPreviousSignIn: Bool
    let sessionDidChangeNotification: Notification.Name
    var restoreResult: Result<GoogleSession, Error>
    var signInResult: Result<GoogleSession, Error>
    var refreshResult: Result<GoogleSession?, Error>
    private(set) var restoreCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var signInRequestedScopes: [Set<String>] = []

    init(
        isConfigured: Bool = true,
        hasPreviousSignIn: Bool = false,
        sessionDidChangeNotification: Notification.Name = .googleCalendarSessionDidChange,
        restoreResult: Result<GoogleSession, Error> = .success(fixtureSession),
        signInResult: Result<GoogleSession, Error> = .success(fixtureSession),
        refreshResult: Result<GoogleSession?, Error> = .success(fixtureSession)
    ) {
        self.isConfigured = isConfigured
        self.hasPreviousSignIn = hasPreviousSignIn
        self.sessionDidChangeNotification = sessionDidChangeNotification
        self.restoreResult = restoreResult
        self.signInResult = signInResult
        self.refreshResult = refreshResult
    }

    func restorePreviousSignIn() async throws -> GoogleSession {
        restoreCallCount += 1
        return try restoreResult.get()
    }

    func signIn(withPresentingWindow _: NSWindow, requestedScopes: Set<String>) async throws -> GoogleSession {
        signInRequestedScopes.append(requestedScopes)
        return try signInResult.get()
    }

    func refreshCurrentSession() async throws -> GoogleSession? {
        try refreshResult.get()
    }

    func disconnect() async throws {
        disconnectCallCount += 1
    }
}

@MainActor
private final class MockGoogleCalendarAPIClient: GoogleCalendarAPIClientProviding {
    private let calendarsResult: Result<[GoogleCalendarListItem], Error>
    private let eventsResult: Result<[GoogleCalendarEvent], Error>
    private(set) var fetchEventsCallCount = 0

    init(
        calendars: [GoogleCalendarListItem] = [],
        events: [GoogleCalendarEvent] = []
    ) {
        calendarsResult = .success(calendars)
        eventsResult = .success(events)
    }

    func fetchCalendarList(accessToken _: String) async throws -> [GoogleCalendarListItem] {
        try calendarsResult.get()
    }

    func fetchUpcomingEvents(
        accessToken _: String,
        calendars _: [GoogleCalendarListItem],
        now _: Date,
        daysAhead _: Int
    ) async throws -> [GoogleCalendarEvent] {
        fetchEventsCallCount += 1
        return try eventsResult.get()
    }
}

private func isolatedUserDefaults() -> UserDefaults {
    let suiteName = "GoogleCalendarStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@MainActor
private func seedSelectedCalendars(_ ids: [String], defaults: UserDefaults) {
    guard let data = try? JSONEncoder().encode(ids) else {
        preconditionFailure("Static calendar identifiers must be JSON encodable")
    }
    defaults.set(String(data: data, encoding: .utf8), forKey: GoogleCalendarStore.selectedCalendarIDsKey)
}
