import CoreMedia
import Foundation
import os

/// 録音クリティカル経路から分離して、表示用の最新音量だけを低頻度で計算する。
final class AudioLevelMeteringWorker: Sendable {
    typealias Handler = @Sendable (_ source: RecordingAudioSource, _ level: Double) async -> Void

    private let continuation: AsyncStream<CapturedAudioChunk>.Continuation
    private let workerTask: Task<Void, Never>
    private let isAcceptingFrames = OSAllocatedUnfairLock(initialState: true)

    init(
        source: RecordingAudioSource,
        updateInterval: TimeInterval = 0.1,
        handler: @escaping Handler
    ) {
        let pair = AsyncStream.makeStream(
            of: CapturedAudioChunk.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation = pair.continuation
        workerTask = Task.detached(priority: .utility) {
            var lastUpdateTime: TimeInterval?
            for await chunk in pair.stream {
                guard !Task.isCancelled else { return }
                let chunkTime = chunk.sessionRelativeStartTime.seconds
                if let lastUpdateTime,
                   chunkTime - lastUpdateTime < updateInterval {
                    continue
                }

                let level = AudioLevelCalculator.normalizedLevel(in: chunk.buffer)
                guard !Task.isCancelled else { return }
                lastUpdateTime = chunkTime
                await handler(source, level)
            }
        }
    }

    func enqueue(_ chunk: CapturedAudioChunk) {
        guard isAcceptingFrames.withLock({ $0 }) else { return }
        continuation.yield(chunk)
    }

    /// 表示用projectionなので停止drainを待たず、保留中の更新を破棄する。
    func cancel() {
        let shouldCancel = isAcceptingFrames.withLock { isAcceptingFrames in
            guard isAcceptingFrames else { return false }
            isAcceptingFrames = false
            return true
        }
        guard shouldCancel else { return }
        continuation.finish()
        workerTask.cancel()
    }

    func waitUntilFinished() async {
        await workerTask.value
    }
}
