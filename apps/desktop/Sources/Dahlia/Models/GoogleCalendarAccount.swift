import Foundation

struct GoogleCalendarAccount: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let email: String
}
