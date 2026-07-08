import Foundation
import GRDB

/// スクリーンショットを表す GRDB レコード。
struct MeetingScreenshotRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "screenshots"

    var id: UUID
    var meetingId: UUID
    var sessionId: UUID? = nil
    var capturedAt: Date
    var imageData: Data
    var mimeType: String
}
