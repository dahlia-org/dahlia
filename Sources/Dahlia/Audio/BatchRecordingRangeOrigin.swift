import Foundation

/// CAFの先頭フレームが録音セッション内で始まった時刻。
struct BatchRecordingRangeOrigin {
    let source: RecordingAudioSource
    let sessionRelativeOriginSeconds: TimeInterval
}
