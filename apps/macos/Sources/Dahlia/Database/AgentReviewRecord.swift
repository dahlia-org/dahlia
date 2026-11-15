import Foundation
import GRDB

struct AgentReviewRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "agent_reviews"
    var id: String
    var accountID: String
    var threadID: String
    var kind: String
    var snapshot: String
    var model: String?
    var effort: String
    var status: String
    var notified = false
    var createdAt: Date
}
