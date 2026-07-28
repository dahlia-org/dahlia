import Foundation
import GRDB

struct InsightRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "insights"

    var id: UUID
    var vaultId: UUID
    var content: String
    var isAccepted: Bool
    var metadataJSON: String
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
}
