import Foundation
import GRDB

struct ContactRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "contacts"

    var id: UUID
    var vaultId: UUID
    var email: String
    var displayName: String?
    var createdAt: Date
    var updatedAt: Date
}
