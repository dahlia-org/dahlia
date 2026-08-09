import Foundation
@testable import Dahlia

#if canImport(Testing)
@MainActor
final class CancellationAwareGoogleCalendarAPIClient: GoogleCalendarAPIClientProviding {
    private let calendar: CalendarListItem
    private let initialEvents: [CalendarEvent]
    private(set) var fetchEventsCallCount = 0
    private(set) var cancellationObserved = false

    init(calendar: CalendarListItem, initialEvents: [CalendarEvent]) {
        self.calendar = calendar
        self.initialEvents = initialEvents
    }

    func fetchCalendarList(accessToken _: String) async throws -> [CalendarListItem] {
        [calendar]
    }

    func fetchUpcomingEvents(
        accessToken _: String,
        calendars _: [CalendarListItem],
        now _: Date,
        daysAhead _: Int
    ) async throws -> [CalendarEvent] {
        fetchEventsCallCount += 1
        guard fetchEventsCallCount > 1 else { return initialEvents }
        do {
            try await Task.sleep(for: .seconds(60))
            return []
        } catch is CancellationError {
            cancellationObserved = true
            throw CancellationError()
        }
    }

    func waitForFetchEventsCallCount(_ expectedCount: Int) async {
        while fetchEventsCallCount < expectedCount {
            await Task.yield()
        }
    }
}

actor CancellationAwareMacCalendarEventStore: MacCalendarEventStoreProviding {
    nonisolated let initialAuthorizationStatus: MacCalendarAuthorizationStatus = .fullAccess
    private let calendar: CalendarListItem
    private let initialEvents: [CalendarEvent]
    private var fetchEventsCallCount = 0
    private var cancellationObserved = false

    init(calendar: CalendarListItem, initialEvents: [CalendarEvent]) {
        self.calendar = calendar
        self.initialEvents = initialEvents
    }

    func authorizationStatus() -> MacCalendarAuthorizationStatus {
        .fullAccess
    }

    func requestFullAccessToEvents() async throws -> Bool {
        true
    }

    func fetchCalendarList() async throws -> [CalendarListItem] {
        [calendar]
    }

    func fetchUpcomingEvents(
        calendars _: [CalendarListItem],
        now _: Date,
        daysAhead _: Int
    ) async throws -> [CalendarEvent] {
        fetchEventsCallCount += 1
        guard fetchEventsCallCount > 1 else { return initialEvents }
        do {
            try await Task.sleep(for: .seconds(60))
            return []
        } catch is CancellationError {
            cancellationObserved = true
            throw CancellationError()
        }
    }

    func waitForFetchEventsCallCount(_ expectedCount: Int) async {
        while fetchEventsCallCount < expectedCount {
            await Task.yield()
        }
    }

    func didObserveCancellation() -> Bool {
        cancellationObserved
    }
}

enum CalendarRefreshTestError: Error {
    case requestFailed
}
#endif
