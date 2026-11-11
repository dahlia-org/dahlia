import Foundation

/// A Unity AI Gateway service offered to the current sign-in.
struct AgentMCPService: Codable, Equatable, Sendable {
    enum SignInState: String, Codable, Sendable {
        case signedIn
        case signInRequired
        case unknown
    }

    let name: String
    var comment: String?
    var signInState: SignInState?
    /// A failed individual metadata read must not clear a previously cached description.
    var metadataUnavailable: Bool?

    /// Built-in Databricks data/tools use the workspace sign-in, without a per-user external OAuth credential.
    static func requiresUserSignIn(_ name: String) -> Bool {
        switch name {
        case "system.ai.dbsql", "system.ai.sandbox", "system.ai.genie_one_mcp", "system.ai.web_search": false
        default: true
        }
    }
}
