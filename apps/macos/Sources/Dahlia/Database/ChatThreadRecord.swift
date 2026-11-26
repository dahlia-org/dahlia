import Foundation
import GRDB

/// Dahlia calls a persistent conversation a Thread; a provider session is only its resume state.
struct ChatThreadRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "chat_threads"
    var id: String
    var accountID: String
    var projectID: UUID?
    var parentThreadID: String?
    var title: String
    var model: String?
    var reasoningEffort: String?
    var status = "idle"
    var createdAt: Date
    var updatedAt: Date
    var memoryTurns = 0
    var skillIterations = 0
    var lastSeenSeq: Int64 = -1
    var scheduleID: String?
    /// When the user settled it: done for now, kept out of the active list until a run starts in it again.
    var settledAt: Date?
    /// The agent whose thread this is (its conversation, an earlier one, or a task it delegated); nil for other chats.
    var agentID: String?
}
