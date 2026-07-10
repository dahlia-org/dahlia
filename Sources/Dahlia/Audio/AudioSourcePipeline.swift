@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import os

/// 有効な音源ごとに1つだけ作られ、物理 capture と consumer の分配境界を保持する。
final class AudioSourcePipeline: Sendable {
    private struct ClockState {
        var nextFrame: Int64 = 0
    }

    let source: RecordingAudioSource
    let router: AudioFrameRouter
    let captureFormat: AVAudioFormat
    let captureDeviceID: AudioDeviceID?
    let captureBufferSize: AVAudioFrameCount
    let sessionRelativeOrigin: CMTime

    private let clockState = OSAllocatedUnfairLock(initialState: ClockState())
    private let sampleRateTimescale: CMTimeScale

    var sessionRelativeOriginSeconds: TimeInterval {
        sessionRelativeOrigin.seconds
    }

    init(
        source: RecordingAudioSource,
        router: AudioFrameRouter = AudioFrameRouter(),
        captureFormat: AVAudioFormat,
        captureDeviceID: AudioDeviceID? = nil,
        captureBufferSize: AVAudioFrameCount = 4096,
        sessionRelativeOrigin: CMTime = .zero
    ) {
        self.source = source
        self.router = router
        self.captureFormat = captureFormat
        self.captureDeviceID = captureDeviceID
        self.captureBufferSize = captureBufferSize
        self.sessionRelativeOrigin = sessionRelativeOrigin
        sampleRateTimescale = CMTimeScale(captureFormat.sampleRate.rounded())
    }

    /// capture callback ごとに呼び出し、同一音源内で単調増加するセッション相対時刻を付与する。
    func capture(_ buffer: AVAudioPCMBuffer) -> CapturedAudioChunk {
        clockState.withLock { state in
            let frameOffset = CMTime(value: state.nextFrame, timescale: sampleRateTimescale)
            let chunk = CapturedAudioChunk(
                source: source,
                buffer: buffer,
                sessionRelativeStartTime: CMTimeAdd(sessionRelativeOrigin, frameOffset)
            )
            state.nextFrame += Int64(buffer.frameLength)
            return chunk
        }
    }
}
