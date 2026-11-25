import Foundation
import GRDB

/// A deadline a Worker set for itself; when due it becomes a timer event.
struct AgentTimerRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_timers"
    var id: String
    var accountID: String
    var taskID: String?
    var note: String
    var dueAt: Date
    var firedAt: Date?
    var createdAt: Date
}
