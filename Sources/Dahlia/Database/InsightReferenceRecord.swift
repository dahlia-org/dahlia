import Foundation
import GRDB

struct InsightReferenceRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "insight_references"

    var insightId: UUID
    var resourceType: CustomerResourceType
    var resourceId: UUID
    var referenceRole: InsightReferenceRole
    var createdAt: Date
}
