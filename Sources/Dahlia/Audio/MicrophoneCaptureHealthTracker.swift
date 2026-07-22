@preconcurrency import AVFoundation
import Foundation
import os

final class MicrophoneCaptureHealthTracker: Sendable {
    private static let levelSampleInterval = Duration.seconds(5)

    private struct State {
        var captureID: UUID?
        var startedAt: ContinuousClock.Instant?
        var lastBufferAt: ContinuousClock.Instant?
        var nextLevelSampleAt: ContinuousClock.Instant?
        var intervalBufferCount = 0
        var totalBufferCount = 0
        var totalFrameCount: Int64 = 0
        var lastLevel: Double?

        func snapshot(
            captureID: UUID,
            at now: ContinuousClock.Instant
        ) -> MicrophoneCaptureHealthSnapshot? {
            guard self.captureID == captureID,
                  let startedAt else { return nil }
            return MicrophoneCaptureHealthSnapshot(
                captureID: captureID,
                elapsed: startedAt.duration(to: now),
                intervalBufferCount: intervalBufferCount,
                totalBufferCount: totalBufferCount,
                totalFrameCount: totalFrameCount,
                lastLevel: lastLevel,
                lastBufferAge: lastBufferAt?.duration(to: now)
            )
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func begin(captureID: UUID, at now: ContinuousClock.Instant = .now) {
        state.withLock { state in
            state = State(
                captureID: captureID,
                startedAt: now,
                nextLevelSampleAt: now
            )
        }
    }

    func recordBuffer(
        captureID: UUID,
        frameLength: AVAudioFrameCount,
        at now: ContinuousClock.Instant = .now
    ) -> Bool {
        state.withLock { state in
            guard state.captureID == captureID else { return false }
            state.intervalBufferCount += 1
            state.totalBufferCount += 1
            state.totalFrameCount += Int64(frameLength)
            state.lastBufferAt = now
            guard let nextLevelSampleAt = state.nextLevelSampleAt,
                  now >= nextLevelSampleAt else { return false }
            state.nextLevelSampleAt = now.advanced(by: Self.levelSampleInterval)
            return true
        }
    }

    func recordLevel(_ level: Double, captureID: UUID) {
        state.withLock { state in
            guard state.captureID == captureID else { return }
            state.lastLevel = level
        }
    }

    func snapshot(
        captureID: UUID,
        at now: ContinuousClock.Instant = .now,
        resetsInterval: Bool = true
    ) -> MicrophoneCaptureHealthSnapshot? {
        state.withLock { state in
            guard let snapshot = state.snapshot(captureID: captureID, at: now) else { return nil }
            if resetsInterval {
                state.intervalBufferCount = 0
            }
            return snapshot
        }
    }

    func finish(
        captureID: UUID,
        at now: ContinuousClock.Instant = .now
    ) -> MicrophoneCaptureHealthSnapshot? {
        state.withLock { state in
            guard let snapshot = state.snapshot(captureID: captureID, at: now) else { return nil }
            state = State()
            return snapshot
        }
    }

    func reset() {
        state.withLock { $0 = State() }
    }
}
