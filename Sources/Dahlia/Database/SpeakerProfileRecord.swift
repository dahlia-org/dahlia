import Foundation
import GRDB

struct SpeakerProfileRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "speaker_profiles"

    var id: UUID
    var vaultId: UUID
    var contactId: UUID
    var embeddingSpaceId: UUID
    var representative: Data
    var contributingMeetingCount: Int
    var createdAt: Date
    var updatedAt: Date
}
