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

    static func applyCanonical(id: UUID, workspaceId: UUID, value: SyncCanonicalPayload, in db: Database) throws {
        guard let meetingId = value.meetingId, let fileId = value.fileId, let createdAt = value.createdAt,
              try FileRecord.fetchOne(db, key: fileId)?.workspaceId == workspaceId,
              try MeetingRecord.fetchOne(db, key: meetingId)?.workspaceId == workspaceId else {
            throw SyncTransactionQueueError.invalidReceipt
        }
        try Self(
            id: id,
            meetingId: meetingId,
            fileId: fileId,
            capturedAt: value.capturedAt,
            sessionId: value.sessionId,
            createdAt: createdAt
        ).save(db)
    }
}
