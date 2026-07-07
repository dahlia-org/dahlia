import Foundation

struct MeetingDateGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let date: Date
    let meetings: [MeetingOverviewItem]
}

enum MeetingDateGrouping {
    static func groups(
        from meetings: [MeetingOverviewItem],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [MeetingDateGroup] {
        let grouped = Dictionary(grouping: meetings) { item in
            calendar.startOfDay(for: item.createdAt)
        }

        return grouped.keys.sorted(by: >).map { day in
            MeetingDateGroup(
                id: ISO8601DateFormatter().string(from: day),
                title: title(for: day, calendar: calendar, now: now),
                date: day,
                meetings: grouped[day, default: []].sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt {
                        return lhs.createdAt > rhs.createdAt
                    }
                    return lhs.meetingId.uuidString > rhs.meetingId.uuidString
                }
            )
        }
    }

    private static func title(for day: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return L10n.today
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return L10n.yesterday
        }

        return day.formatted(.dateTime.year().month(.wide).day())
    }
}
