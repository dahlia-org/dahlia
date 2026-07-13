import AppKit
import Combine
@preconcurrency import EventKit
import Foundation

enum MacCalendarAuthorizationStatus: Equatable {
    case notDetermined
    case restricted
    case denied
    case fullAccess
    case writeOnly

    var canReadEvents: Bool {
        self == .fullAccess
    }
}

@MainActor
protocol MacCalendarEventStoreProviding: AnyObject {
    var authorizationStatus: MacCalendarAuthorizationStatus { get }

    func requestFullAccessToEvents() async throws -> Bool
    func fetchCalendarList() throws -> [CalendarListItem]
    func fetchUpcomingEvents(calendars: [CalendarListItem], now: Date, daysAhead: Int) throws -> [CalendarEvent]
}

@MainActor
final class MacCalendarStore: ObservableObject {
    static let selectedCalendarIDsKey = "macCalendarSelectedCalendarIDs"
    static let didInitializeSelectionKey = "macCalendarDidInitializeSelection"

    enum State: Equatable {
        case notDetermined
        case accessDenied
        case loading
        case needsCalendarSelection
        case loaded
        case failed
    }

    static let shared = MacCalendarStore()

    @Published private(set) var state: State
    @Published private(set) var availableCalendars: [CalendarListItem] = []
    @Published private(set) var upcomingEvents: [CalendarEvent] = []
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var selectedCalendarIDs: Set<String>

    var isAuthorized: Bool {
        eventStoreProvider.authorizationStatus.canReadEvents
    }

    var isBusy: Bool {
        state == .loading
    }

    private let eventStoreProvider: any MacCalendarEventStoreProviding
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private let refreshInterval: TimeInterval
    private let daysAhead: Int
    private let storeChangedNotification: Notification.Name?
    private var lastRefreshAt: Date?
    private var storeChangedTask: Task<Void, Never>?

    init(
        eventStoreProvider: any MacCalendarEventStoreProviding = EventKitMacCalendarEventStore(),
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        refreshInterval: TimeInterval = 300,
        daysAhead: Int = 7,
        storeChangedNotification: Notification.Name? = .EKEventStoreChanged
    ) {
        self.eventStoreProvider = eventStoreProvider
        self.userDefaults = userDefaults
        self.now = now
        self.refreshInterval = refreshInterval
        self.daysAhead = daysAhead
        self.storeChangedNotification = storeChangedNotification
        self.selectedCalendarIDs = Self.loadSelectedCalendarIDs(from: userDefaults)
        self.state = Self.state(for: eventStoreProvider.authorizationStatus)

        if let storeChangedNotification {
            storeChangedTask = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: storeChangedNotification) {
                    await self?.handleEventStoreChanged()
                }
            }
        }
    }

    deinit {
        storeChangedTask?.cancel()
    }

    func requestAccess() async {
        beginLoading()
        do {
            let granted = try await eventStoreProvider.requestFullAccessToEvents()
            guard granted else {
                clearRuntimeState()
                state = .accessDenied
                return
            }
            await refreshIfNeeded(force: true)
        } catch {
            handle(error)
            recomputeStateIfNeeded()
        }
    }

    func refreshIfNeeded(force: Bool = false) async {
        guard eventStoreProvider.authorizationStatus.canReadEvents else {
            clearRuntimeState()
            state = Self.state(for: eventStoreProvider.authorizationStatus)
            return
        }

        if !force,
           let lastRefreshAt,
           now().timeIntervalSince(lastRefreshAt) < refreshInterval {
            recomputeStateIfNeeded()
            return
        }

        beginLoading()
        do {
            availableCalendars = try eventStoreProvider.fetchCalendarList()
            initializeSelectionIfNeeded()
            pruneSelectedCalendars()

            guard !selectedCalendarIDs.isEmpty else {
                if !upcomingEvents.isEmpty { upcomingEvents = [] }
                lastRefreshAt = nil
                lastErrorMessage = nil
                recomputeState()
                return
            }

            let selectedCalendars = availableCalendars.filter { selectedCalendarIDs.contains($0.id) }
            upcomingEvents = try eventStoreProvider.fetchUpcomingEvents(
                calendars: selectedCalendars,
                now: now(),
                daysAhead: daysAhead
            )
            lastRefreshAt = now()
            lastErrorMessage = nil
            recomputeState()
        } catch {
            handle(error)
            recomputeStateIfNeeded()
        }
    }

    func toggleCalendarSelection(id: String) {
        guard isAuthorized else { return }
        var nextSelection = selectedCalendarIDs
        nextSelection.toggle(id)

        updateSelectedCalendarIDs(nextSelection)
        Task {
            await refreshIfNeeded(force: true)
        }
    }

    func setCalendarSelection(_ ids: Set<String>) {
        guard isAuthorized else { return }
        updateSelectedCalendarIDs(ids)
        Task {
            await refreshIfNeeded(force: true)
        }
    }

    private func beginLoading() {
        lastErrorMessage = nil
        state = .loading
    }

    private func handle(_ error: Error) {
        lastErrorMessage = error.localizedDescription
        state = .failed
        ErrorReportingService.capture(error, context: ["source": "macCalendar"])
    }

    private func recomputeState() {
        let newState: State = if !eventStoreProvider.authorizationStatus.canReadEvents {
            Self.state(for: eventStoreProvider.authorizationStatus)
        } else if !availableCalendars.isEmpty, selectedCalendarIDs.isEmpty {
            .needsCalendarSelection
        } else {
            .loaded
        }
        if state != newState {
            state = newState
        }
    }

    private func recomputeStateIfNeeded() {
        guard state != .loading else { return }
        if state != .failed {
            recomputeState()
        }
    }

    private func clearRuntimeState() {
        if !availableCalendars.isEmpty { availableCalendars = [] }
        if !upcomingEvents.isEmpty { upcomingEvents = [] }
        lastRefreshAt = nil
    }

    private func initializeSelectionIfNeeded() {
        guard !userDefaults.bool(forKey: Self.didInitializeSelectionKey) else { return }
        updateSelectedCalendarIDs(Set(availableCalendars.map(\.id)))
        userDefaults.set(true, forKey: Self.didInitializeSelectionKey)
    }

    private func updateSelectedCalendarIDs(_ ids: Set<String>, pruneUnavailable: Bool = false) {
        let availableIDs = Set(availableCalendars.map(\.id))
        let filtered = if pruneUnavailable {
            ids.intersection(availableIDs)
        } else {
            availableIDs.isEmpty ? ids : ids.intersection(availableIDs)
        }
        selectedCalendarIDs = filtered
        Self.persistSelectedCalendarIDs(filtered, to: userDefaults)
    }

    private func pruneSelectedCalendars() {
        updateSelectedCalendarIDs(selectedCalendarIDs, pruneUnavailable: true)
    }

    private func handleEventStoreChanged() async {
        lastRefreshAt = nil
        await refreshIfNeeded(force: true)
    }

    private static func state(for authorizationStatus: MacCalendarAuthorizationStatus) -> State {
        switch authorizationStatus {
        case .notDetermined:
            .notDetermined
        case .restricted, .denied, .writeOnly:
            .accessDenied
        case .fullAccess:
            .loaded
        }
    }

    private static func loadSelectedCalendarIDs(from userDefaults: UserDefaults) -> Set<String> {
        guard let json = userDefaults.string(forKey: selectedCalendarIDsKey),
              let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return Set(ids)
    }

    private static func persistSelectedCalendarIDs(_ ids: Set<String>, to userDefaults: UserDefaults) {
        let sorted = Array(ids).sorted()
        guard let data = try? JSONEncoder().encode(sorted),
              let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        userDefaults.set(json, forKey: Self.selectedCalendarIDsKey)
    }
}

@MainActor
final class EventKitMacCalendarEventStore: MacCalendarEventStoreProviding {
    private let eventStore: EKEventStore
    private let calendar: Calendar

    init(eventStore: EKEventStore = EKEventStore(), calendar: Calendar = .current) {
        self.eventStore = eventStore
        self.calendar = calendar
    }

    var authorizationStatus: MacCalendarAuthorizationStatus {
        Self.authorizationStatus(from: EKEventStore.authorizationStatus(for: .event))
    }

    func requestFullAccessToEvents() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func fetchCalendarList() throws -> [CalendarListItem] {
        let defaultCalendarID = eventStore.defaultCalendarForNewEvents?.calendarIdentifier
        return eventStore.calendars(for: .event)
            .map { calendar in
                CalendarListItem(
                    id: calendar.calendarIdentifier,
                    title: calendar.title.nilIfBlank ?? L10n.macOSCalendarUntitledCalendar,
                    colorHex: calendar.color?.hexString,
                    isPrimary: calendar.calendarIdentifier == defaultCalendarID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary {
                    return lhs.isPrimary && !rhs.isPrimary
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    func fetchUpcomingEvents(calendars: [CalendarListItem], now: Date, daysAhead: Int) throws -> [CalendarEvent] {
        let intervalEnd = calendar.date(byAdding: .day, value: daysAhead, to: now) ?? now
        let selectedCalendars = calendars.compactMap { eventStore.calendar(withIdentifier: $0.id) }
        guard !selectedCalendars.isEmpty else { return [] }

        let predicate = eventStore.predicateForEvents(withStart: now, end: intervalEnd, calendars: selectedCalendars)
        let events = eventStore.events(matching: predicate).compactMap { Self.makeEvent(from: $0) }
        return Self.sortAndFilter(events, now: now, intervalEnd: intervalEnd)
    }

    static func makeEvent(from event: EKEvent) -> CalendarEvent? {
        guard let startDate = event.startDate,
              let endDate = event.endDate,
              let calendar = event.calendar
        else { return nil }

        let occurrenceDate = event.occurrenceDate ?? startDate
        let platformId = "\(event.eventIdentifier ?? event.calendarItemIdentifier)::\(Int(occurrenceDate.timeIntervalSince1970))"
        let recurrenceId = recurrenceId(
            occurrenceDate: event.occurrenceDate,
            isAllDay: event.isAllDay
        )
        return CalendarEvent(
            id: "\(calendar.calendarIdentifier)::\(platformId)",
            calendarID: calendar.calendarIdentifier,
            calendarName: calendar.title.nilIfBlank ?? L10n.macOSCalendarUntitledCalendar,
            calendarColorHex: calendar.color?.hexString,
            platform: CalendarEventPlatform.macOSCalendar,
            platformId: platformId,
            title: event.title.nilIfBlank ?? L10n.macOSCalendarUntitledEvent,
            description: event.notes?.nilIfBlank ?? "",
            icalUid: event.calendarItemExternalIdentifier.nilIfBlank,
            recurrenceId: recurrenceId,
            startDate: startDate,
            endDate: max(endDate, startDate),
            isAllDay: event.isAllDay,
            hasOtherAttendees: event.attendees?.contains { !$0.isCurrentUser } == true,
            isDeclined: event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined,
            isOutOfOffice: event.availability == .unavailable,
            conferenceURI: CalendarConferenceURIExtractor.conferenceURI(
                url: event.url,
                textFields: [event.notes, event.location]
            )
        )
    }

    static func sortAndFilter(_ events: [CalendarEvent], now: Date, intervalEnd: Date) -> [CalendarEvent] {
        events
            .filter { $0.endDate >= now && $0.startDate <= intervalEnd }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                if lhs.isAllDay != rhs.isAllDay {
                    return lhs.isAllDay && !rhs.isAllDay
                }
                let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
                if titleComparison != .orderedSame {
                    return titleComparison == .orderedAscending
                }
                return lhs.id < rhs.id
            }
    }

    static func recurrenceId(
        occurrenceDate: Date?,
        isAllDay: Bool,
        defaultTimeZone: TimeZone = .current
    ) -> String {
        guard let occurrenceDate else { return ICalendarRecurrenceID.singleEvent }
        return isAllDay
            ? ICalendarRecurrenceID.date(occurrenceDate, timeZone: defaultTimeZone)
            : ICalendarRecurrenceID.dateTime(occurrenceDate)
    }

    private static func authorizationStatus(from status: EKAuthorizationStatus) -> MacCalendarAuthorizationStatus {
        switch status {
        case .notDetermined:
            .notDetermined
        case .restricted:
            .restricted
        case .denied:
            .denied
        case .fullAccess:
            .fullAccess
        case .writeOnly:
            .writeOnly
        @unknown default:
            .denied
        }
    }
}

private extension NSColor {
    var hexString: String? {
        guard let color = usingColorSpace(.deviceRGB) else { return nil }
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
