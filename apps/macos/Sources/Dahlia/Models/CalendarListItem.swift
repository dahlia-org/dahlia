import Foundation

struct CalendarListItem: Identifiable, Equatable {
    let id: String
    let title: String
    let colorHex: String?
    let isPrimary: Bool
}
