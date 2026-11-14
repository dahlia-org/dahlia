import Foundation
import GRDB

struct SummaryVersionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "summary_versions"

    var meetingId: UUID
    var version: Int
    var title: String
    var document: String
    var savedAt: Date
    var isCurrent: Bool
}
