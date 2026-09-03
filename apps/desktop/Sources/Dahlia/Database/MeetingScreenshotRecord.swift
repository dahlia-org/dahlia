import Foundation
import GRDB

/// スクリーンショットを表す GRDB レコード。
struct MeetingScreenshotRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "screenshots"

    var id: UUID
    var meetingId: UUID
    var sessionId: UUID?
    var capturedAt: Date
    var imageData: Data
    var mimeType: String
    var ocrText: String?
    var caption: String?
    var syncUploadedConnectionId: UUID?
    var serverRevision: Int?
}
