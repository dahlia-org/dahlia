import Foundation
import GRDB

struct OrganizationRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "organizations"

    var id: UUID
    var vaultId: UUID
    var parentOrganizationId: UUID?
    var nodeKind: OrganizationNodeKind
    var name: String
    var description = ""
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    var isRootOrganization: Bool {
        nodeKind == .organization && parentOrganizationId == nil
    }
}
