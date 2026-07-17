@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import os

/// 有効な音源ごとに1つだけ作られ、物理 capture と consumer の分配境界を保持する。
final class AudioSourcePipeline: Sendable {
    private struct ClockState {
        var nextFrame: Int64 = 0
        var sessionRelativeOrigin: CMTime
    }

    let source: RecordingAudioSource
    let router: AudioFrameRouter
    let captureFormat: AVAudioFormat
    let captureDeviceID: AudioDeviceID?
    let captureBufferSize: AVAudioFrameCount
    private let clockState: OSAllocatedUnfairLock<ClockState>
    private let sampleRateTimescale: CMTimeScale

    var sessionRelativeOriginSeconds: TimeInterval {
        clockState.withLock { $0.sessionRelativeOrigin.seconds }
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
        clockState = OSAllocatedUnfairLock(initialState: ClockState(sessionRelativeOrigin: sessionRelativeOrigin))
        sampleRateTimescale = CMTimeScale(captureFormat.sampleRate.rounded())
    }

    /// capture開始前に、先頭フレームのセッション相対時刻を確定する。
    func setSessionRelativeOrigin(seconds: TimeInterval) {
        clockState.withLock { state in
            guard state.nextFrame == 0 else { return }
            state.sessionRelativeOrigin = CMTime(seconds: max(0, seconds), preferredTimescale: 1_000_000)
        }
    }

    /// capture callback ごとに呼び出し、同一音源内で単調増加するセッション相対時刻を付与する。
    func capture(_ buffer: AVAudioPCMBuffer) -> CapturedAudioChunk {
        clockState.withLock { state in
            let frameOffset = CMTime(value: state.nextFrame, timescale: sampleRateTimescale)
            let chunk = CapturedAudioChunk(
                source: source,
                buffer: buffer,
                sessionRelativeStartTime: CMTimeAdd(state.sessionRelativeOrigin, frameOffset)
            )
            state.nextFrame += Int64(buffer.frameLength)
            return chunk
        }
    }
}
