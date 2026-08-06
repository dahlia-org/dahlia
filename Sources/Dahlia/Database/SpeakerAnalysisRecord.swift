import Foundation
import GRDB

struct SpeakerAnalysisRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "speaker_analyses"

    var id: UUID
    var recordingSessionId: UUID
    var audioSource: RecordingAudioSource
    var embeddingSpaceId: UUID?
    var state: SpeakerAnalysisState
    var failureReason: String?
    var createdAt: Date
    var updatedAt: Date
}
