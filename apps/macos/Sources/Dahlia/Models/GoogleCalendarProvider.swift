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

    /// Only an explicitly saved connection uses the proxy. An unset or removed choice uses Google directly.
    static func current(defaults: UserDefaults = .standard) -> Self {
        let connections = ProviderAccountDirectory.databricksConnections()
        switch defaults.string(forKey: userDefaultsKey) {
        case "google":
            return .google
        case let saved?:
            if let id = UUID(uuidString: saved), connections.contains(where: { $0.id == id }) { return .databricks(connectionID: id) }
        default:
            break
        }
        return .google
    }

    static func save(_ provider: Self, defaults: UserDefaults = .standard) {
        defaults.set(provider.databricksConnectionID?.uuidString ?? "google", forKey: userDefaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
