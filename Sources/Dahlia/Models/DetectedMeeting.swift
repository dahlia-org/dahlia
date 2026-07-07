import Foundation

/// 検出されたビデオ会議の情報。
struct DetectedMeeting: Identifiable {
    let id = UUID()
    let title: String
    let appName: String
    let bundleIdentifier: String
    let calendarEvent: CalendarEvent?
}
