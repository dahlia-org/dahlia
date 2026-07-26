import Foundation
import GRDB

struct InsightRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "insights"

    var id: UUID
    var vaultId: UUID
    var content: String
    var reviewState: InsightReviewState
    var metadataJSON: String
    var createdAt: Date
    var updatedAt: Date
}
