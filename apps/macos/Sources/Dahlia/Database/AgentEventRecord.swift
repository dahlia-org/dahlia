import Foundation
import GRDB

/// One row of the inbox: an external item, a Worker result, a user decision or split, or a timer firing.
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
    var actionID: String?
    var payload: String
    var status: String
    var createdAt: Date
    var deliveryRunID: UUID?
}
