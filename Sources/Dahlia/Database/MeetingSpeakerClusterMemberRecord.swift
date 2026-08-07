import Foundation
import GRDB

struct MeetingSpeakerClusterMemberRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "meeting_speaker_cluster_members"

    var meetingSpeakerId: UUID
    var clusterId: UUID
    var createdAt: Date
}
