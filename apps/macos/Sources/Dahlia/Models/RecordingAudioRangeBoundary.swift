import Foundation

struct RecordingAudioRangeBoundary: Equatable {
    let source: RecordingAudioSource
    let segmentId: UUID
    let frame: Int64
    let sessionOffsetSeconds: TimeInterval
}
