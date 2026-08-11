import Foundation
import GRDB

/// Durable progress for one source. Required sources define the session-wide minimum cursor.
struct RecordingAudioSourceProgressRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "recording_audio_source_progress"

    var recordingSessionId: UUID
    var source: RecordingAudioSource
    var isRequired: Bool
    var captureState: RecordingAudioSourceCaptureState
    var durableThroughOffsetSeconds: TimeInterval
    var lastContiguousReadySegmentIndex: Int?
    var failureCode: String?
    var createdAt: Date
    var updatedAt: Date
}
