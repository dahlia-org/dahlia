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

    /// The Pi provider ID whose requests carry this account's token: a Databricks connection's workspace host, as Pi
    /// names any Unity AI Gateway, so several connections can serve at once.
    var piProviderID: String {
        switch self {
        case let .databricks(connectionID):
            ProviderAccountDirectory.databricksConnections().first { $0.id == connectionID }?.piProviderID
                ?? PiProviderConfiguration.legacyDatabricksProviderID
        case .dahlia: "dahlia"
        }
    }
}

/// The Databricks connections in `provider_accounts`, oldest first, which the app's one account uses.
enum ProviderAccountDirectory {
    struct Connection: Equatable, Sendable {
        let id: UUID
        let workspaceURL: URL
        /// The workspace host, as Pi names the connection's provider.
        var piProviderID: String { AgentMCPProvider.id(for: workspaceURL) }
    }

    /// Replaces the connections for the current task, so tests never read the app database.
    @TaskLocal static var connections: [Connection]?

    static func databricksConnections() -> [Connection] {
        connections ?? ((try? DatabricksOAuthStorage.local().loadConnections()) ?? []).compactMap { connection in
            URL(string: connection.host).map { Connection(id: connection.id, workspaceURL: $0) }
        }
    }
}

extension CodexRuntimeProvider {
    /// The provider accounts this runtime account uses. This is the one place that maps an account kind to the
    /// connections its features use; features ask for a capability instead of switching on the account. The app's one
    /// account (Local) uses every Databricks connection.
    var providerAccounts: [ProviderAccount] {
        switch self {
        case .local: ProviderAccountDirectory.databricksConnections().map { .databricks(connectionID: $0.id) }
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
