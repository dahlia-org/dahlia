import Foundation

/// The provider account that supplies Google Calendar: Google itself (a direct sign-in) or a Databricks connection,
/// which reads it through its Unity Catalog connection. Both read the same calendars, so only one is used at a time.
enum GoogleCalendarProvider: Hashable, Sendable {
    case google
    case databricks(connectionID: UUID)

    nonisolated static let userDefaultsKey = "googleCalendarProvider"
    static let didChange = Notification.Name("GoogleCalendarProviderDidChange")

    var databricksConnectionID: UUID? {
        guard case let .databricks(connectionID) = self else { return nil }
        return connectionID
    }

    /// The saved choice. Unset, or naming a connection the account no longer has, follows the account's Databricks
    /// connection when it has one, as before the choice existed.
    static func current(defaults: UserDefaults = .standard) -> Self {
        let databricks = ProviderAccountDirectory.account(offering: .calendar)?.databricksConnectionID
        switch defaults.string(forKey: userDefaultsKey) {
        case "google":
            return .google
        case let saved? where UUID(uuidString: saved) == databricks:
            if let databricks { return .databricks(connectionID: databricks) }
        default:
            break
        }
        return databricks.map { .databricks(connectionID: $0) } ?? .google
    }

    static func save(_ provider: Self, defaults: UserDefaults = .standard) {
        defaults.set(provider.databricksConnectionID?.uuidString ?? "google", forKey: userDefaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
