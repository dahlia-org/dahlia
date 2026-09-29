import Foundation
import GRDB

struct DocumentRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "documents"
    var id: UUID
    var meetingId: UUID
    var schemaVersion = 1
    var revision = 0
    var generation: UUID?
    var checkpoint: String
    var checkpointSequence: Int64 = 0
    var projectionSequence: Int64 = 0
    var text = ""
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date?
    var resident = true
    var locallyEdited = false
}
