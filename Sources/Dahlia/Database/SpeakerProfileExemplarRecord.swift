import Foundation
import GRDB

struct SpeakerProfileExemplarRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "speaker_profile_exemplars"

    var profileId: UUID
    var ordinal: Int
    var meetingSpeakerId: UUID
    var embedding: Data
    var quality: Double
}
