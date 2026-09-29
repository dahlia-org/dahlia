import Foundation
import GRDB

struct DocumentRecoveryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "document_recoveries"
    var id: UUID
    var meetingId: UUID
    var blocksJSON: String
    var reason: String
    var pending: Bool
    var createdAt: Date
}
