import Foundation

struct DatabricksConnection: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let host: String
    /// The signed-in user and workspace ID, fetched after sign-in. Older saved connections have neither until then.
    var email: String?
    var workspaceID: String?
    /// The name the user gave the connection, a provider account; nil shows its workspace and email.
    var name: String?

    /// Shared by capabilities of this provider account; saved in the provider account’s settingsJSON, separately from credentials.
    var catalogSchema: DatabricksCatalogSchema? {
        get async throws { try await DatabricksCatalogSchema.load(connectionID: id) }
    }

    /// The workspace's host name without the cloud domain, such as `dbc-a5d4177a-49dc`.
    var workspaceName: String {
        let name = URL(string: host)?.host() ?? host
        return name.split(separator: ".").first.map(String.init) ?? name
    }

    /// The workspace's host name, such as `dbc-a5d4177a-49dc.cloud.databricks.com`.
    var hostName: String {
        URL(string: host)?.host() ?? host
    }

    /// "workspace (email)", or the workspace alone until the user is known.
    var accountLabel: String {
        email.map { "\(workspaceName) (\($0))" } ?? workspaceName
    }

    /// The name the user gave it, or else its workspace and email.
    var displayName: String {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? accountLabel
    }
}
