import Foundation

struct RecordingAudioIntegrityMetadata: Equatable, Sendable {
    let frameCount: Int64
    let sampleRate: Double
    let channelCount: Int
    let byteCount: Int64
    let sha256: Data
}
