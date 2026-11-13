import Foundation
import GRDB

/// Dahlia calls a persistent conversation a Thread; a provider session is only its resume state.
struct ChatThreadRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "chat_threads"
    var id: String
    var accountID: String
    var workspaceID: UUID
    var projectID: UUID?
    var parentThreadID: String?
    var title: String
    var model: String?
    var reasoningEffort: String?
    var status = "idle"
    var createdAt: Date
    var updatedAt: Date
}
