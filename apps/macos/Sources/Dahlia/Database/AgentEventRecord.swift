import Foundation
import GRDB

/// A signal for Super Agent, with enough reference information for a task to read its source again.
struct AgentEventRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_event_inbox"
    var id: String
    var agentID: String
    var sourceID: String?
    var key: String?
    var topic: String?
    var note: String
    var ref: String?
    var occurredAt: Date
    var taskID: String?
    var handledAt: Date?
    var createdAt: Date
}
