import Foundation

struct CodexChatCalendarEventContext: Equatable {
    let icalUID: String?
    let title: String
    let description: String
    let start: Date
    let end: Date
}
