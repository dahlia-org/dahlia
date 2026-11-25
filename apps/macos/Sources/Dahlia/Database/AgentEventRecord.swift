import Foundation
import GRDB

/// One row of the inbox: an item intake read, or the user's answer to an Item. `taskID` names the Task it went to.
struct AgentEventRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_event_inbox"
    var id: String
    var accountID: String
    var kind: String
    var sourceID: String?
    var externalID: String?
    var topicKey: String?
    var sender: String?
    var subject: String?
    var excerpt: String
    var url: String?
    var ref: String?
    var occurredAt: Date?
    var taskID: String?
    var payload: String
    var status: String
    var createdAt: Date
}
