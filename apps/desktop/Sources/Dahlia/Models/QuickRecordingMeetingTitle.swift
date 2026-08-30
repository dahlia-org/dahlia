import Foundation

enum QuickRecordingMeetingTitle {
    static func make(at date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let format = Date.ISO8601FormatStyle(timeZone: timeZone)
            .year()
            .month()
            .day()
            .dateSeparator(.dash)
            .dateTimeSeparator(.space)
            .time(includingFractionalSeconds: false)
            .timeSeparator(.colon)
        return L10n.quickRecordingMeetingName(timestamp: date.formatted(format))
    }
}
