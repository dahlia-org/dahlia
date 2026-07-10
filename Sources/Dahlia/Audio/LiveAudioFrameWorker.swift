@preconcurrency import AVFoundation
import os

/// capture callback からライブ変換処理を切り離す低遅延 bounded queue。
/// backlog 超過時は古いフレームを捨て、batch consumer には影響させない。
final class LiveAudioFrameWorker: Sendable {
    typealias Consumer = @Sendable (CapturedAudioChunk) -> Bool
    typealias FailureHandler = @Sendable () -> Void

    enum BufferingMode: Equatable {
        case lossless
        case lowLatency(maximumFrameCount: Int)
    }

    private struct State {
        var isAcceptingFrames = true
    }

    private let continuation: AsyncStream<CapturedAudioChunk>.Continuation
    private let workerTask: Task<Void, Never>
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        bufferingMode: BufferingMode,
        consumer: @escaping Consumer,
        onFailure: @escaping FailureHandler
    ) {
        let bufferingPolicy: AsyncStream<CapturedAudioChunk>.Continuation.BufferingPolicy = switch bufferingMode {
        case .lossless:
            .unbounded
        case let .lowLatency(maximumFrameCount):
            .bufferingNewest(max(1, maximumFrameCount))
        }
        let pair = AsyncStream.makeStream(
            of: CapturedAudioChunk.self,
            bufferingPolicy: bufferingPolicy
        )
        continuation = pair.continuation
        workerTask = Task.detached(priority: .userInitiated) {
            for await chunk in pair.stream {
                guard consumer(chunk) else {
                    onFailure()
                    return
                }
            }
        }
    }

    func enqueue(_ chunk: CapturedAudioChunk) {
        let isAcceptingFrames = state.withLock { $0.isAcceptingFrames }
        guard isAcceptingFrames else { return }

        continuation.yield(chunk)
    }

    func finish() {
        let shouldFinish = state.withLock { state in
            guard state.isAcceptingFrames else { return false }
            state.isAcceptingFrames = false
            return true
        }
        if shouldFinish {
            continuation.finish()
        }
    }

    func waitUntilFinished() async {
        await workerTask.value
    }
}
