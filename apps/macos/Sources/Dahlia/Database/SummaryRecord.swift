import DahliaRuntimeSupport
import Foundation
import GRDB

/// ミーティング要約を表す GRDB レコード。
struct SummaryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "summaries"

    var meetingId: UUID
    var title: String
    var createdAt: Date

}
