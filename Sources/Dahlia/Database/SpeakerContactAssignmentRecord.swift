import Foundation
import GRDB

struct SpeakerContactAssignmentRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "speaker_contact_assignments"

    var meetingSpeakerId: UUID
    var contactId: UUID
    var origin: SpeakerAssignmentOrigin
    var createdAt: Date
    var updatedAt: Date
}
