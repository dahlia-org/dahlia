import Foundation

struct ProjectCalendarDay: Identifiable, Equatable {
    let date: Date
    let isInMonth: Bool
    let meetings: [MeetingSidebarItem]

    var id: Date { date }
    var visibleMeetings: ArraySlice<MeetingSidebarItem> { meetings.prefix(3) }
    var hiddenMeetingCount: Int { meetings.count - visibleMeetings.count }
}

enum ProjectCalendarMonth {
    static func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        calendar.dateInterval(of: .month, for: date)
    }

    static func date(
        byAddingMonths value: Int,
        to date: Date,
        calendar: Calendar = .current
    ) -> Date {
        guard let monthStart = interval(containing: date, calendar: calendar)?.start,
              let result = calendar.date(byAdding: .month, value: value, to: monthStart) else { return date }
        return result
    }

    static func days(
        containing date: Date,
        meetings: [MeetingSidebarItem],
        calendar: Calendar = .current
    ) -> [ProjectCalendarDay] {
        guard let month = interval(containing: date, calendar: calendar) else { return [] }
        let firstDay = calendar.startOfDay(for: month.start)
        let weekday = calendar.component(.weekday, from: firstDay)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: firstDay) else { return [] }
        let monthDayCount = calendar.dateComponents([.day], from: firstDay, to: month.end).day ?? 0
        let cellCount = ((leadingDays + monthDayCount + 6) / 7) * 7
        let meetingsByDay = Dictionary(grouping: meetings) {
            calendar.startOfDay(for: $0.effectiveRecordingStartedAt)
        }

        return (0 ..< cellCount).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            return ProjectCalendarDay(
                date: day,
                isInMonth: day >= month.start && day < month.end,
                meetings: meetingsByDay[day, default: []]
            )
        }
    }
}
