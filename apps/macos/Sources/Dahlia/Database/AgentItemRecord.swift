import Foundation
import GRDB

/// One row of the user's inbox: a question, a report, or a suggestion from Super Agent. `revision` is
/// the version the user answers; an answer to an older one changes nothing.
struct AgentItemRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_user_inbox"
    var id: String
    var agentID: String
    var kind: String
    var status: String
    var taskID: String?
    var title: String
    var body: String
    var options: String
    var recommended: Int?
    var answer: String?
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
}
