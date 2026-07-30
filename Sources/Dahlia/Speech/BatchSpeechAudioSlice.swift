import Foundation

/// A frame range in one immutable CAF used as part of a logical batch-recognition run.
struct BatchSpeechAudioSlice: Sendable {
    let audioURL: URL
    let startFrame: Int64
    let frameCount: Int64
}
