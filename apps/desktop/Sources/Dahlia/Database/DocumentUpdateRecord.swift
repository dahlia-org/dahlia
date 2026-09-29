import Foundation
import GRDB

struct DocumentUpdateRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "document_updates"
    var id: Int64?
    var documentId: UUID
    var payload: String
    var pending: Bool
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
