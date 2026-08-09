import Foundation
import GRDB

struct MeetingSpeakerExemplarRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "meeting_speaker_exemplars"

    var meetingSpeakerId: UUID
    var ordinal: Int
    var embedding: Data
    var quality: Double
}
