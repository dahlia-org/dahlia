import Foundation

/// The calendar service is independent of the account that authenticates its transport.
/// Microsoft 365 is reserved for a future Databricks adapter; it is not offered in the catalog yet.
enum CalendarService: String, Sendable {
    case googleCalendar
    case microsoft365
}

struct CalendarProviderConnection: Identifiable, Equatable, Sendable {
    let provider: ProviderAccount
    let service: CalendarService
    let displayName: String
    var id: String { "\(service.rawValue).\(provider.connectionID.uuidString)" }

    var googleRoute: GoogleCalendarProvider? {
        guard service == .googleCalendar else { return nil }
        switch provider {
        case let .google(id): return .google(accountID: id)
        case let .databricks(id): return .databricks(connectionID: id)
        case .dahlia: return nil
        }
    }
}

enum CalendarConnectionState: Equatable, Sendable {
    case unconfigured, signedOut, loading, needsCalendarSelection, loaded, failed

    var requiresUserAttention: Bool {
        switch self {
        case .unconfigured, .signedOut, .needsCalendarSelection, .failed: true
        case .loading, .loaded: false
        }
    }
}
