import Foundation

struct DatabricksConnection: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let host: String
    /// The signed-in user and workspace ID, fetched after sign-in. Older saved connections have neither until then.
    var email: String?
    var workspaceID: String?

    /// The workspace's host name without the cloud domain, such as `dbc-a5d4177a-49dc`.
    var workspaceName: String {
        let name = URL(string: host)?.host() ?? host
        return name.split(separator: ".").first.map(String.init) ?? name
    }

    /// "workspace (email)", or the workspace alone until the user is known.
    var accountLabel: String {
        email.map { "\(workspaceName) (\($0))" } ?? workspaceName
    }
}
