import Foundation

/// カレンダー予定の通知時刻を決定する純粋なプランナー。
enum CalendarMeetingNotificationPlanner {
    static let leadTime: TimeInterval = 60
    private static let minimumSchedulingDelay: TimeInterval = 1

    /// 未来の時刻指定が必須なため、開始1分前を過ぎている未開始予定は直ちに通知する。
    static func notificationDate(for event: CalendarEvent, now: Date) -> Date? {
        guard !event.isAllDay, event.startDate > now else { return nil }

        let preferredDate = event.startDate.addingTimeInterval(-leadTime)
        return max(preferredDate, now.addingTimeInterval(minimumSchedulingDelay))
    }

    static func schedule(
        for events: [CalendarEvent],
        filter: CalendarEventFilter,
        now: Date,
        limit: Int
    ) -> [(event: CalendarEvent, notificationDate: Date)] {
        Array(
            events
                .deduplicatedAcrossSources()
                .filter(filter.includes)
                .compactMap { event -> (event: CalendarEvent, notificationDate: Date)? in
                    guard let notificationDate = notificationDate(for: event, now: now) else {
                        return nil
                    }
                    return (event, notificationDate)
                }
                .sorted { lhs, rhs in
                    if lhs.notificationDate != rhs.notificationDate {
                        return lhs.notificationDate < rhs.notificationDate
                    }
                    return lhs.event.id < rhs.event.id
                }
                .prefix(limit)
        )
    }

    static func staleDeliveredIdentifiers(
        from deliveredIdentifiers: Set<String>,
        scheduledIdentifiers: Set<String>
    ) -> [String] {
        deliveredIdentifiers.subtracting(scheduledIdentifiers).sorted()
    }
}
