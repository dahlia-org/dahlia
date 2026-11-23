import Foundation

/// A kind of service that a provider account offers to Dahlia's features. Storage and database are defined for later
/// use; no provider account offers them yet.
enum ProviderCapability: String, CaseIterable, Sendable {
    case model
    case mcp
    case calendar
    case storage
    case database
}

/// An external connection whose credential the app holds in the Keychain. Pi holds the ChatGPT and Anthropic sign-ins
/// itself, so they are not provider accounts here.
enum ProviderAccount: Hashable, Sendable {
    case databricks(connectionID: UUID)
    case dahlia(connectionID: UUID)

    var connectionID: UUID {
        switch self {
        case let .databricks(connectionID), let .dahlia(connectionID): connectionID
        }
    }

    var databricksConnectionID: UUID? {
        guard case let .databricks(connectionID) = self else { return nil }
        return connectionID
    }

    var capabilities: Set<ProviderCapability> {
        switch self {
        case .databricks: [.model, .mcp, .calendar]
        case .dahlia: [.model]
        }
    }

    /// The Pi provider ID whose requests carry this account's token.
    var piProviderID: String {
        switch self {
        case .databricks: PiProviderConfiguration.databricksProviderIDs[0]
        case .dahlia: "dahlia"
        }
    }
}

/// The Databricks connections in `provider_accounts`, oldest first, which the app's one account uses.
enum ProviderAccountDirectory {
    /// Replaces the connections for the current task, so tests never read the app database.
    @TaskLocal static var connectionIDs: [UUID]?

    static func databricksConnectionIDs() -> [UUID] {
        connectionIDs ?? ((try? DatabricksOAuthStorage.local().loadConnections().map(\.id)) ?? [])
    }
}

extension CodexRuntimeProvider {
    /// The provider accounts this runtime account uses. This is the one place that maps an account kind to the
    /// connections its features use; features ask for a capability instead of switching on the account. The app's one
    /// account (Local) uses every Databricks connection.
    var providerAccounts: [ProviderAccount] {
        switch self {
        // shortcut: only the oldest Databricks connection, while every one shares the Pi provider ID `databricks`;
        // use them all once each has its own provider ID (its host).
        case .local: ProviderAccountDirectory.databricksConnectionIDs().prefix(1).map { .databricks(connectionID: $0) }
        case let .databricks(connectionID): [.databricks(connectionID: connectionID)]
        case let .dahlia(connectionID): [.dahlia(connectionID: connectionID)]
        }
    }

    func providerAccount(offering capability: ProviderCapability) -> ProviderAccount? {
        providerAccounts.first { $0.capabilities.contains(capability) }
    }

    /// The Databricks connection, for features that only Databricks offers (such as Omnigent).
    var databricksConnectionID: UUID? {
        providerAccounts.lazy.compactMap(\.databricksConnectionID).first
    }

    /// The provider account behind a Pi provider ID that asks Dahlia for a token, if this account bridges it.
    func providerAccount(piProviderID: String) -> ProviderAccount? {
        providerAccounts.first { $0.piProviderID == piProviderID }
    }
}
