import Foundation
import GRDB

/// How far the user delegates one MCP tool: arguments fixed by `conditions`, and an automation level from 1 to 4.
struct AgentPolicyRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_action_policies"
    var id: String
    var accountID: String
    var server: String
    var tool: String
    var conditions: String
    var level: Int
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date
}
