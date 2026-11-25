import Foundation
import GRDB

/// One external write a Worker chose. Approval binds to `approvedRevision`; it runs at most once.
struct AgentActionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_action_outbox"
    var id: String
    var accountID: String
    var taskID: String
    var revision: Int
    var server: String
    var tool: String
    var arguments: String
    var principal: String
    var status: String
    var approvedRevision: Int?
    var policyID: String?
    var result: String?
    var createdAt: Date
    var updatedAt: Date
}
