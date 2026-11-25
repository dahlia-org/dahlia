import Foundation
import GRDB

/// A Task: a thread Super Agent launched, with whether it is still in progress. The thread does the work; only the user
/// or Super Agent ends a Task, so a thread that stopped is not a finished one.
struct AgentTaskRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_tasks"
    var id: String
    var accountID: String
    var title: String
    /// The message the thread was launched with.
    var instructions: String
    var threadID: String?
    var status: String
    var createdAt: Date
    var updatedAt: Date
}
