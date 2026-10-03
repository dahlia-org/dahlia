import Foundation

struct BatchTranscriptionAudioRange: Sendable {
    let startFrame: Int64
    let frameCount: Int64
    let sessionOffsetSeconds: TimeInterval
    let recordedLocaleIdentifiers: [String]
}
