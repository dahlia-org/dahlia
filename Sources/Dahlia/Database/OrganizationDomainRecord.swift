import Foundation
import GRDB

struct OrganizationDomainRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "organization_domains"

    var vaultId: UUID
    var domainName: String
    var organizationId: UUID
    var isPrimary: Bool
    var firstObservedAt: Date
    var lastObservedAt: Date
}
