import Foundation

/// iCalendar の UID と RECURRENCE-ID で特定される予定の論理キー。
struct CalendarEventKey: Hashable, Codable {
    let icalUid: String
    let recurrenceId: String

    init(icalUid: String, recurrenceId: String) {
        self.icalUid = icalUid
        self.recurrenceId = recurrenceId
    }

    init?(icalUid: String?, recurrenceId: String) {
        guard let icalUid = icalUid?.nilIfBlank else { return nil }
        self.init(icalUid: icalUid, recurrenceId: recurrenceId)
    }
}
