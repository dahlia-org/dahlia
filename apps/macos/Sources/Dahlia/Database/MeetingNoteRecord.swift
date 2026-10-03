import Foundation
import GRDB

/// 手動ノートを表す GRDB レコード。meetingId が PK（1 meeting = 1 note）。
struct MeetingNoteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notes"

    var meetingId: UUID
    var text: String
    var createdAt: Date
    var updatedAt: Date
}
