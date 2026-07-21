import Foundation
import GRDB

/// App-managed recording audio represented by one immutable physical CAF segment.
struct RecordingAudioSegmentRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "recording_audio_segments"

    var id: UUID
    var recordingSessionId: UUID
    var source: RecordingAudioSource
    var segmentIndex: Int
    var generationId: UUID
    var state: RecordingAudioSegmentState
    var partialRelativePath: String
    var finalRelativePath: String
    var sampleRate: Double
    var channelCount: Int
    var sealedFrameCount: Int64?
    var sessionStartOffsetSeconds: TimeInterval
    var sessionEndOffsetSeconds: TimeInterval?
    var byteCount: Int64?
    var sha256: Data?
    var finalizationStartedAt: Date?
    var integrityVerifiedAt: Date?
    var finalizedAt: Date?
    var purgeRequestedAt: Date?
    var purgedAt: Date?
    var failureStage: String?
    var failureCode: String?
    var createdAt: Date
    var updatedAt: Date
}
