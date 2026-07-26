import Foundation
import GRDB

struct GlossaryTermReferenceRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "glossary_term_references"

    var glossaryTermId: UUID
    var resourceType: CustomerResourceType
    var resourceId: UUID
    var createdAt: Date
}
