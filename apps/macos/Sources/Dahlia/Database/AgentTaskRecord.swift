import Foundation
import GRDB

/// One piece of work the Router opened. Source grants and revocable Work grants retain their separate origins.
struct AgentTaskRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_tasks"
    var id: String
    var accountID: String
    var title: String
    var instructions: String
    var threadID: String?
    var status: String
    var servers = "[]"
    var workServers = "[]"
    var createdAt: Date
    var updatedAt: Date
}
