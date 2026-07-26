import Foundation
import GRDB

struct MeetingParticipantRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "meeting_participants"

    var meetingId: UUID
    var contactId: UUID
    var role: MeetingParticipantRole
    var responseStatus: MeetingParticipantResponseStatus
    var source: String
    var createdAt: Date
    var updatedAt: Date
}
