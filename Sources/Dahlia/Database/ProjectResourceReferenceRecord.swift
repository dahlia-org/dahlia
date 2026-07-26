import Foundation
import GRDB

struct ProjectResourceReferenceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "project_resource_references"

    var id: UUID
    var projectId: UUID
    var resourceType: CustomerResourceType
    var resourceId: UUID
    var relationLabel: String
    var createdAt: Date
    var updatedAt: Date
}
