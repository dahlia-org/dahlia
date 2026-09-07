import Foundation
import GRDB

struct SummaryBodyRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "summary_bodies"

    var meetingId: UUID
    var document: String
}
