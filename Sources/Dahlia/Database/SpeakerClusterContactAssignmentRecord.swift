import Foundation
import GRDB

struct SpeakerClusterContactAssignmentRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "speaker_cluster_contact_assignments"

    var clusterId: UUID
    var contactId: UUID
    var origin: SpeakerAssignmentOrigin
    var createdAt: Date
    var updatedAt: Date
}
