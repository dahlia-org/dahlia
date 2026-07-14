import Foundation

struct MenuBarCalendarAgenda: Equatable {
    private static let menuBarTitleLimit = 24

    let events: [CalendarEvent]
    let featuredEvent: CalendarEvent?
    let featuredEventIsOngoing: Bool

    init(
        googleEvents: [CalendarEvent],
        macEvents: [CalendarEvent],
        enabledSources: Set<CalendarSource>,
        filter: CalendarEventFilter,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        var sourceEvents: [CalendarEvent] = []
        if enabledSources.contains(.google) {
            sourceEvents.append(contentsOf: googleEvents)
        }
        if enabledSources.contains(.macOS) {
            sourceEvents.append(contentsOf: macEvents)
        }

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        events = sourceEvents
            .deduplicatedAcrossSources()
            .filter(filter.includes)
            .filter { $0.endDate > now && $0.startDate < tomorrow }
            .sorted(by: Self.sortEvents)

        let timedEvents = events.filter { !$0.isAllDay }
        if let ongoingEvent = timedEvents
            .filter({ $0.startDate <= now && $0.endDate > now })
            .max(by: Self.compareOngoingEvents) {
            featuredEvent = ongoingEvent
            featuredEventIsOngoing = true
        } else {
            featuredEvent = timedEvents.first(where: { $0.startDate > now })
            featuredEventIsOngoing = false
        }
    }

    func labelText(showsTitle: Bool, showsCountdown: Bool, now: Date) -> String? {
        guard let featuredEvent else { return nil }

        var components: [String] = []
        if showsTitle {
            components.append(Self.truncatedTitle(featuredEvent.resolvedMeetingTitle))
        }
        if showsCountdown {
            components.append(countdownText(now: now))
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    func accessibilityLabel(now: Date) -> String? {
        guard let featuredEvent else { return nil }
        let participation = featuredEvent.isAttending ? ", \(L10n.calendarAttending)" : ""
        return "\(featuredEvent.resolvedMeetingTitle), \(countdownText(now: now))\(participation)"
    }

    func countdownText(now: Date) -> String {
        guard let featuredEvent else { return "" }
        let targetDate = featuredEventIsOngoing ? featuredEvent.endDate : featuredEvent.startDate

        if targetDate.timeIntervalSince(now) < 60 {
            return featuredEventIsOngoing ? L10n.menuBarEndingSoon : L10n.menuBarStartingSoon
        }

        let remainingMinutes = Self.remainingMinutes(from: now, to: targetDate)
        let duration = Self.durationText(minutes: remainingMinutes)
        return featuredEventIsOngoing ? L10n.menuBarEndsIn(duration) : L10n.menuBarStartsIn(duration)
    }

    static func remainingMinutes(from now: Date, to targetDate: Date) -> Int {
        max(0, Int(ceil(targetDate.timeIntervalSince(now) / 60)))
    }

    static func durationText(minutes: Int) -> String {
        let hours = minutes / 60
        let remainingMinutes = minutes % 60

        if hours > 0, remainingMinutes > 0 {
            return L10n.menuBarHoursAndMinutes(hours, remainingMinutes)
        }
        if hours > 0 {
            return L10n.menuBarHours(hours)
        }
        return L10n.menuBarMinutes(remainingMinutes)
    }

    private static func truncatedTitle(_ title: String) -> String {
        guard title.count > menuBarTitleLimit else { return title }
        return "\(title.prefix(menuBarTitleLimit))…"
    }

    private static func sortEvents(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        if lhs.isAllDay != rhs.isAllDay {
            return lhs.isAllDay
        }
        if lhs.startDate != rhs.startDate {
            return lhs.startDate < rhs.startDate
        }
        if lhs.endDate != rhs.endDate {
            return lhs.endDate < rhs.endDate
        }
        if lhs.title != rhs.title {
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private static func compareOngoingEvents(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        if lhs.startDate != rhs.startDate {
            return lhs.startDate < rhs.startDate
        }
        if lhs.endDate != rhs.endDate {
            return lhs.endDate > rhs.endDate
        }
        return lhs.id < rhs.id
    }
}
