import Foundation

/// カレンダー予定の開催回を、取得元をまたいで安定して識別するキー。
struct CalendarAutoRecordingEventID: Codable, Hashable, Sendable {
    private enum Kind: String, Codable {
        case iCalendar
        case source
    }

    private let kind: Kind
    private let icalUid: String?
    private let recurrenceId: String
    private let platform: String?
    private let calendarID: String?
    private let platformId: String?

    init(event: CalendarEvent) {
        if let key = event.key {
            kind = .iCalendar
            icalUid = key.icalUid
            recurrenceId = key.recurrenceId
            platform = nil
            calendarID = nil
            platformId = nil
        } else {
            kind = .source
            icalUid = nil
            recurrenceId = event.recurrenceId
            platform = event.platform
            calendarID = event.calendarID
            platformId = Self.fallbackPlatformId(for: event)
        }
    }

    var sortKey: String {
        switch kind {
        case .iCalendar:
            "icalendar:\(icalUid ?? ""):\(recurrenceId)"
        case .source:
            "source:\(platform ?? ""):\(calendarID ?? ""):\(platformId ?? ""):\(recurrenceId)"
        }
    }

    private static func fallbackPlatformId(for event: CalendarEvent) -> String {
        guard event.platform == CalendarEventPlatform.macOSCalendar,
              let separator = event.platformId.range(of: "::", options: .backwards),
              Int(event.platformId[separator.upperBound...]) != nil else {
            return event.platformId
        }
        return String(event.platformId[..<separator.lowerBound])
    }
}
