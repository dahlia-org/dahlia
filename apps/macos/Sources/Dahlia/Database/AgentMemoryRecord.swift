import Foundation
import GRDB

struct AgentMemoryRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    static let databaseTableName = "agent_memories"
    var id: UUID
    var accountID: String
    var target: String
    var content: String
    var createdBy: String
    var createdAt: Date
    var updatedAt: Date
    var position = 0
}
