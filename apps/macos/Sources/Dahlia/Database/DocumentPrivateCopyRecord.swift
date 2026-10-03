import Foundation
import GRDB

struct DocumentPrivateCopyRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "document_private_copies"
    var id: UUID
    var workspaceId: UUID
    var meetingId: UUID?
    var kind = "notes"
    var title = ""
    var checkpoint: String
    var text: String
    var createdAt: Date
    var updatedAt: Date
    enum CodingKeys: String, CodingKey { case id, workspaceId = "workspace_id", meetingId, kind, title, checkpoint, text, createdAt, updatedAt }
}
