import Foundation
import GRDB

/// An idle launch has no run in which to keep its retry key.
struct ChatThreadLaunchRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "chat_thread_launches"
    var requesterID: String
    var rootRunID: UUID
    var requestID: String
    var threadID: String
}
