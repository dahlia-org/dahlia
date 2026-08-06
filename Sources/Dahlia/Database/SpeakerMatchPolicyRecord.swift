import Foundation
import GRDB

struct SpeakerMatchPolicyRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "speaker_match_policy"

    var id: Int
    var formatVersion: Int
    var state: SpeakerMatchPolicyState
    var minimumSimilarity: Double?
    var minimumMargin: Double?
    var updatedAt: Date

    var policy: SpeakerMatchPolicy {
        SpeakerMatchPolicy(
            formatVersion: formatVersion,
            state: state,
            minimumSimilarity: minimumSimilarity.map(Float.init),
            minimumMargin: minimumMargin.map(Float.init)
        )
    }
}
