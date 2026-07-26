import Foundation
import GRDB

struct OrganizationRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "organizations"

    var id: UUID
    var vaultId: UUID
    var parentOrganizationId: UUID?
    var nodeKind: OrganizationNodeKind
    var name: String
    var createdAt: Date
    var updatedAt: Date
}
