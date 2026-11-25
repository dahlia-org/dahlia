import Foundation
import GRDB

struct ChatRunRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "chat_runs"
    var id: UUID
    var threadID: String
    var requestedByThreadID: String?
    var rootRunID: UUID
    var status: String
    var input: String
    var model: String?
    var effort: String
    var approvalMethod: String
    var clientRequestID: String?
    var resultDeliveredAt: Date?
    var createdAt: Date
    var resultExcerpt = ""
    var suppressAutomaticNotification = false
    /// The user stopped this run; results of work it started never restart its thread.
    var stoppedByUser = false
    var origin = "user"
    var profile = "interactive"
    var startedAt: Date?
    var completedAt: Date?
    var requestedByRunID: UUID?
    /// Acceptance order for work that has not started yet.
    var logicalSequence: Int64?
    /// Actual first-start order, inherited by continuations; createdAt remains this attempt's timestamp.
    var executionSequence: Int64?
}
