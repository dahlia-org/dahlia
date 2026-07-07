import Foundation

enum CalendarEventPlatform {
    static let googleCalendar = "GoogleCalendar"
    static let macOSCalendar = "MacOSCalendar"
}

struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let calendarID: String
    let calendarName: String
    let calendarColorHex: String?
    let platform: String
    let platformId: String
    let title: String
    let description: String
    let icalUid: String?
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let meetingURL: URL?

    init(
        id: String,
        calendarID: String,
        calendarName: String,
        calendarColorHex: String?,
        platform: String = CalendarEventPlatform.googleCalendar,
        platformId: String,
        title: String,
        description: String,
        icalUid: String?,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        meetingURL: URL?
    ) {
        self.id = id
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.calendarColorHex = calendarColorHex
        self.platform = platform
        self.platformId = platformId
        self.title = title
        self.description = description
        self.icalUid = icalUid
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.meetingURL = meetingURL
    }
}

private struct CalendarEventOccurrenceKey: Hashable {
    let icalUid: String
    let startDate: Date
}

extension [CalendarEvent] {
    /// Google と macOS の両ソースが同じ物理イベントを返した場合に 1 件へ畳み込む。
    /// iCalUID は繰り返しイベントでは系列単位のため開始時刻と組で照合し、
    /// 会議 URL などの情報が揃っている Google 側を優先する。同一ソース内の重複
    /// （複数カレンダーに同じ予定がある場合）は従来どおり残す。
    func deduplicatedAcrossSources() -> [CalendarEvent] {
        var indexByKey: [CalendarEventOccurrenceKey: Int] = [:]
        var result: [CalendarEvent] = []

        for event in self {
            guard let icalUid = event.icalUid, !icalUid.isEmpty else {
                result.append(event)
                continue
            }

            let key = CalendarEventOccurrenceKey(icalUid: icalUid, startDate: event.startDate)
            guard let existingIndex = indexByKey[key] else {
                indexByKey[key] = result.count
                result.append(event)
                continue
            }

            let existing = result[existingIndex]
            if existing.platform == event.platform {
                result.append(event)
            } else if existing.platform != CalendarEventPlatform.googleCalendar,
                      event.platform == CalendarEventPlatform.googleCalendar {
                result[existingIndex] = event
            }
        }
        return result
    }
}
