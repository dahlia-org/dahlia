import Foundation

/// One registered Google identity. Calendar and Drive share this account's credential, not other Google accounts'.
struct GoogleProviderAccount: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let account: GoogleCalendarAccount
    var name: String?

    var displayName: String { name ?? "\(L10n.google) (\(account.email.nilIfBlank ?? account.displayName))" }

    static let didChange = Notification.Name("GoogleProviderAccountsDidChange")
    static let sessionDidChange = Notification.Name("GoogleProviderAccountSessionDidChange")
}

struct GoogleProviderAccountSessionChange: Sendable {
    let accountID: UUID
    let disconnected: Bool
}
