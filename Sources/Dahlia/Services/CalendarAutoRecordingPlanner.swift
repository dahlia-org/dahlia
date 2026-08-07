import Foundation

/// 保存済み予約と最新のカレンダー予定から、自動録音の実行時刻を決める純粋なプランナー。
enum CalendarAutoRecordingPlanner {
    static func dueEvents(
        events: [CalendarEvent],
        selections: [CalendarAutoRecordingSelection],
        now: Date
    ) -> [CalendarEvent] {
        matchingEvents(events: events, selections: selections, now: now)
            .filter { $0.startDate <= now }
    }

    static func nextEvaluationDate(
        events: [CalendarEvent],
        selections: [CalendarAutoRecordingSelection],
        now: Date
    ) -> Date? {
        let nextStartDate = matchingEvents(events: events, selections: selections, now: now)
            .lazy
            .map(\.startDate)
            .first { $0 > now }
        let nextEndDate = selections.lazy.map(\.endDate).filter { $0 > now }.min()
        return [nextStartDate, nextEndDate].compactMap(\.self).min()
    }

    private static func matchingEvents(
        events: [CalendarEvent],
        selections: [CalendarAutoRecordingSelection],
        now: Date
    ) -> [CalendarEvent] {
        let selectedIDs = Set(selections.map(\.eventID))
        return events
            .deduplicatedAcrossSources()
            .filter { event in
                !event.isAllDay
                    && event.endDate > now
                    && selectedIDs.contains(CalendarAutoRecordingEventID(event: event))
            }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                return CalendarAutoRecordingEventID(event: lhs).sortKey
                    < CalendarAutoRecordingEventID(event: rhs).sortKey
            }
    }
}
