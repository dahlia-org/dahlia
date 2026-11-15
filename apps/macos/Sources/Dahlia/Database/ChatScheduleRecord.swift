import Foundation
import GRDB

struct ChatScheduleRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "chat_schedules"
    var id: String
    var accountID: String
    var threadID: String
    var name: String
    var schedule: String
    var prompt: String
    var skills: String
    var allowedTools: String
    var revision: Int
    var enabled: Bool
    var notify = true
    var nextFireAt: Date?
    var createdAt: Date
    var updatedAt: Date
}
