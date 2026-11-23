import Foundation
import GRDB

/// One piece of work the Router opened. `servers` lists the MCP servers its Worker may read, chosen from those the
/// user allowed for work.
struct AgentTaskRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_tasks"
    var id: String
    var accountID: String
    var title: String
    var instructions: String
    var threadID: String?
    var status: String
    var servers = "[]"
    var createdAt: Date
    var updatedAt: Date
}
