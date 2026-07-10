import Foundation

/// CAFの先頭フレームが録音セッション内で始まった時刻。
struct BatchRecordingRangeOrigin {
    let source: RecordingAudioSource
    let startFrame: Int64
    let sessionRelativeOriginSeconds: TimeInterval
}

struct BatchRecordingConsumerAttachment {
    let consumer: AudioFrameRouter.BatchConsumer
    let origin: BatchRecordingRangeOrigin
}
