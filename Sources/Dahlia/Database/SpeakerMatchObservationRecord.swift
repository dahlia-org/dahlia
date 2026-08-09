import Foundation
import GRDB

struct SpeakerMatchObservationRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "speaker_match_observations"

    var meetingSpeakerId: UUID
    var embeddingSpaceId: UUID
    var top1ContactId: UUID?
    var top1Score: Double?
    var top2ContactId: UUID?
    var top2Score: Double?
    var margin: Double?
    var state: SpeakerMatchObservationState
    var unknownReason: SpeakerMatchUnknownReason?
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
}
