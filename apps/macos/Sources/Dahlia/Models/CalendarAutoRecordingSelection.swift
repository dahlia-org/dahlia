import Foundation

/// 自動録音を一度だけ試みるカレンダー予定の開催回。
struct CalendarAutoRecordingSelection: Codable, Equatable, Sendable {
    let eventID: CalendarAutoRecordingEventID
    let startDate: Date
    let endDate: Date

    init(event: CalendarEvent) {
        eventID = CalendarAutoRecordingEventID(event: event)
        startDate = event.startDate
        endDate = event.endDate
    }
}
