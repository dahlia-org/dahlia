import Foundation
import GRDB

struct MeetingAttachmentRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "meeting_attachments"

    var id: UUID
    var meetingId: UUID
    var fileId: UUID
    var capturedAt: Date?
    var sessionId: UUID?
    var createdAt: Date

}
