import Foundation
import GRDB

struct MeetingTagRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "meeting_tags"

    var meetingId: UUID
    var tagId: Int64
}
