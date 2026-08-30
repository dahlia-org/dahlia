import Foundation
import GRDB

struct OrganizationMembershipRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "organization_memberships"

    var organizationId: UUID
    var contactId: UUID
    var roleLabel: String?
    var createdAt: Date
}
