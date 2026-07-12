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

    static func staleDeliveredIdentifiers(
        from deliveredIdentifiers: Set<String>,
        scheduledIdentifiers: Set<String>
    ) -> [String] {
        deliveredIdentifiers.subtracting(scheduledIdentifiers).sorted()
    }
}
