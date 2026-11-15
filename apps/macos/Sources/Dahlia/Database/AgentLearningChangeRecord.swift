import Foundation
import GRDB

struct AgentLearningChangeRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_learning_changes"
    var id: UUID
    var accountID: String
    var kind: String
    var target: String
    var before: String?
    var after: String?
    var status: String
    var source: String
    var threadID: String?
    var reviewID: String?
    var createdAt: Date
}
