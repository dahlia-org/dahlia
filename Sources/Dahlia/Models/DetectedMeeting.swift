import Foundation

/// 検出されたビデオ会議の情報。
struct DetectedMeeting: Identifiable, Codable {
    let id: UUID
    let title: String
    let appName: String
    let bundleIdentifier: String
    let calendarEvent: CalendarEvent?

    init(
        id: UUID = UUID(),
        title: String,
        appName: String,
        bundleIdentifier: String,
        calendarEvent: CalendarEvent?
    ) {
        self.id = id
        self.title = title
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.calendarEvent = calendarEvent
    }
}
