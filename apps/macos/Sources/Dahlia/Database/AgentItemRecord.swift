import Foundation
import GRDB

/// One row of the user's inbox: a question, a write waiting for approval, a report, or a suggestion. `revision` is
/// the version the user answers; an answer to an older one changes nothing.
struct AgentItemRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_user_inbox"
    var id: String
    var accountID: String
    var kind: String
    var status: String
    var taskID: String?
    var actionID: String?
    var title: String
    var body: String
    var options: String
    var recommended: Int?
    var answer: String?
    var revision: Int
    /// A suggested Task (title, instructions, events, servers) that opens when the user accepts the suggestion.
    var proposal: String?
    var createdAt: Date
    var updatedAt: Date
}
