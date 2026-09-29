import Foundation
import GRDB

struct DocumentRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "documents"
    var id: UUID
    var workspaceId: UUID
    var meetingId: UUID?
    var kind = "notes"
    var title = ""
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
    enum CodingKeys: String, CodingKey {
        case id, workspaceId = "workspace_id", meetingId, kind, title, schemaVersion, revision, generation
        case checkpoint, checkpointSequence, projectionSequence, text, createdAt, updatedAt, lastAccessedAt, resident, locallyEdited
    }

    static func notes(in db: Database, meetingID: UUID) throws -> Self? {
        try filter(Column("meetingId") == meetingID).filter(Column("kind") == "notes").fetchOne(db)
    }
}
