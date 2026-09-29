import Foundation
import GRDB

struct DocumentLocalArchiveRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "document_local_archives"
    let id: UUID
    let workspaceId: UUID
    let meetingId: UUID?
    let name: String
    let payload: String
    let createdAt: Date
    enum CodingKeys: String, CodingKey { case id, workspaceId = "workspace_id", meetingId, name, payload, createdAt }
}
