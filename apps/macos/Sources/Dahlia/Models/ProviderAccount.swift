import Foundation
import Synchronization

/// A service offered by a provider account. Storage currently covers Google Drive backup reads; database is reserved.
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
    case google(connectionID: UUID)

    var connectionID: UUID {
        switch self {
        case let .databricks(connectionID), let .dahlia(connectionID), let .google(connectionID): connectionID
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
        case .google: [.calendar, .storage]
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
        case let .google(connectionID): "google-\(connectionID.uuidString)"
        }
    }
}

/// The provider accounts on this Mac. The app's one account uses all of them at once.
enum ProviderAccountDirectory {
    @TaskLocal static var googleAccounts: [GoogleProviderAccount]?
    private static let registeredGoogleAccounts = Mutex<[GoogleProviderAccount]>([])

    static func googleConnections() -> [GoogleProviderAccount] {
        googleAccounts ?? registeredGoogleAccounts.withLock { $0 }
    }

    static func setGoogleAccounts(_ accounts: [GoogleProviderAccount]) -> Bool {
        registeredGoogleAccounts.withLock {
            guard $0 != accounts else { return false }
            $0 = accounts
            return true
        }
    }

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

    /// Replaces the signed-in Dahlia connections for the current task, so tests never share the app's.
    @TaskLocal static var dahliaConnections: [UUID]?
    private static let signedInDahliaConnections = Mutex<[UUID]>([])

    /// The Dahlia connection whose Gateway serves models: the oldest signed-in one.
    static func dahliaConnectionID() -> UUID? {
        // shortcut: Pi has one `dahlia` provider, so only the oldest signed-in connection serves models; name each
        // connection's provider by its host when more than one Dahlia account can be signed in.
        (dahliaConnections ?? signedInDahliaConnections.withLock { $0 }).first
    }

    /// Records the signed-in Dahlia connections, oldest first; true when they changed.
    static func setSignedInDahliaConnections(_ ids: [UUID]) -> Bool {
        signedInDahliaConnections.withLock { current in
            defer { current = ids }
            return current != ids
        }
    }
}

extension ProviderAccountDirectory {
    /// The provider accounts the app's account uses: every Databricks connection, then the signed-in Dahlia account's
    /// Gateway. Features ask for a capability instead of naming a connection.
    static var accounts: [ProviderAccount] {
        databricksConnections().map { .databricks(connectionID: $0.id) }
            + [dahliaConnectionID().map { .dahlia(connectionID: $0) }].compactMap(\.self)
            + googleConnections().map { .google(connectionID: $0.id) }
    }

    static var modelAccounts: [ProviderAccount] { accounts.filter { $0.capabilities.contains(.model) } }

    static func account(offering capability: ProviderCapability) -> ProviderAccount? {
        accounts.first { $0.capabilities.contains(capability) }
    }

    /// The provider account behind a Pi provider ID that asks Dahlia for a token, if the app bridges it.
    static func account(piProviderID: String) -> ProviderAccount? {
        modelAccounts.first { $0.piProviderID == piProviderID }
    }
}
