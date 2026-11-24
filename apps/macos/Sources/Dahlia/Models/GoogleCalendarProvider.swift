import Foundation

/// A Google transport route. Calendar pins one per connection; Drive selects its route explicitly.
/// The saved key retains its previous name for the existing Drive selection.
enum GoogleCalendarProvider: Hashable, Sendable {
    case unassigned
    case google(accountID: UUID)
    case databricks(connectionID: UUID)

    nonisolated static let userDefaultsKey = "googleCalendarProvider"
    static let didChange = Notification.Name("GoogleCalendarProviderDidChange")

    var databricksConnectionID: UUID? {
        guard case let .databricks(connectionID) = self else { return nil }
        return connectionID
    }

    var googleAccountID: UUID? {
        guard case let .google(accountID) = self else { return nil }
        return accountID
    }

    var storageKey: String {
        switch self {
        case .unassigned: "unassigned"
        case let .google(id): "google-\(id.uuidString)"
        case let .databricks(id): "databricks-\(id.uuidString)"
        }
    }

    static func current(defaults: UserDefaults = .standard) -> Self {
        guard let saved = defaults.string(forKey: userDefaultsKey) else { return .unassigned }
        if saved.hasPrefix("google-"), let id = UUID(uuidString: String(saved.dropFirst(7))),
           ProviderAccountDirectory.googleConnections().contains(where: { $0.id == id }) {
            return .google(accountID: id)
        }
        if let id = UUID(uuidString: saved), ProviderAccountDirectory.databricksConnections().contains(where: { $0.id == id }) {
            return .databricks(connectionID: id)
        }
        return .unassigned
    }

    static func save(_ provider: Self, defaults: UserDefaults = .standard) {
        defaults.set(provider.databricksConnectionID?.uuidString ?? provider.storageKey, forKey: userDefaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
