import Foundation

struct SummaryPreviousMeetingMetadata: Equatable {
    let meetingId: UUID
    let name: String
    let recordedAt: Date
    let calendarStart: Date?
    let calendarEnd: Date?
}
