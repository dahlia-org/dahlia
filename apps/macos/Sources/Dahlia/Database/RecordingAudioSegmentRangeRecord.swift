import Foundation
import GRDB

/// A locale range whose frame coordinates are local to one physical segment.
struct RecordingAudioSegmentRangeRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "recording_audio_segment_ranges"

    var id: UUID
    var audioSegmentId: UUID
    var startFrame: Int64
    var frameCount: Int64?
    var sessionOffsetSeconds: TimeInterval
    var localeIdentifier: String
    var createdAt: Date
    var updatedAt: Date
}
