import Foundation
import GRDB

struct GlossaryTermRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "glossary_terms"

    var id: UUID
    var vaultId: UUID
    var term: String
    var definition: String
    var aliasesJSON: String
    var createdAt: Date
    var updatedAt: Date
}
