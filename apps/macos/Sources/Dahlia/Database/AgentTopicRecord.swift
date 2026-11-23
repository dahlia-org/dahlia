import Foundation
import GRDB

/// Which task owns an external conversation (a mail thread, a Slack thread), so its follow-ups skip the Router.
struct AgentTopicRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "agent_event_topics"
    var accountID: String
    var sourceID: String
    var topicKey: String
    var taskID: String
}
