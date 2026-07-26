import Foundation
import GRDB

struct ContactRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "contacts"

    var id: UUID
    var vaultId: UUID
    var email: String?
    var displayName: String?
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    var isProvisional: Bool {
        email == nil
    }
}
