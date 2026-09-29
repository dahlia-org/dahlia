import Foundation
import GRDB

struct DocumentPrivateCopyRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "document_private_copies"
    var id: UUID
    var meetingId: UUID
    var checkpoint: String
    var text: String
    var createdAt: Date
    var updatedAt: Date
}
