import Foundation
import GRDB

struct MeetingSpeakerClusterRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "meeting_speaker_clusters"

    var id: UUID
    var meetingId: UUID
    var audioSource: RecordingAudioSource
    var embeddingSpaceId: UUID
    var representative: Data
    var createdAt: Date
    var updatedAt: Date
}
