@preconcurrency import AVFoundation
import os

/// 1つの物理キャプチャから batch 録音とライブ認識へ同じバッファを分配する。
/// batch は欠落検知付き writer へ同期投入し、live の変換・認識は bounded worker queue へ分離する。
final class AudioFrameRouter: Sendable {
    typealias BatchConsumer = @Sendable (CapturedAudioChunk) -> Void
    typealias LiveConsumer = @Sendable (CapturedAudioChunk) -> Bool
    typealias LiveFailureHandler = @Sendable () -> Void

    private struct Consumers {
        let batch: BatchConsumer?
        let liveWorker: LiveAudioFrameWorker?
    }

    private struct State {
        var batchConsumer: BatchConsumer?
        var liveWorker: LiveAudioFrameWorker?
        var liveFailureHandler: LiveFailureHandler?
        var liveGeneration: UInt64 = 0
        var inFlightRouteCount = 0
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
        var workersWaitingForRouteCompletion: [LiveAudioFrameWorker] = []
        var retiredWorkers: [LiveAudioFrameWorker] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setBatchConsumer(_ consumer: BatchConsumer?) {
        state.withLock { $0.batchConsumer = consumer }
    }

    func setLiveConsumer(
        _ consumer: LiveConsumer?,
        bufferingMode: LiveAudioFrameWorker.BufferingMode = .lossless,
        onFailure: LiveFailureHandler? = nil
    ) {
        let generation = state.withLock { state in
            state.liveGeneration &+= 1
            return state.liveGeneration
        }
        let newWorker = consumer.map { consumer in
            LiveAudioFrameWorker(bufferingMode: bufferingMode, consumer: consumer) { [weak self] in
                self?.liveWorkerFailed(generation: generation)
            }
        }

        let workersToFinish = state.withLock { state -> [LiveAudioFrameWorker] in
            guard state.liveGeneration == generation else {
                return newWorker.map { [$0] } ?? []
            }
            let workersToFinish = retireCurrentLiveWorker(state: &state)
            state.liveWorker = newWorker
            state.liveFailureHandler = onFailure
            return workersToFinish
        }
        workersToFinish.forEach { $0.finish() }
    }

    func removeAllConsumers() {
        let workersToFinish = state.withLock { state -> [LiveAudioFrameWorker] in
            state.batchConsumer = nil
            state.liveGeneration &+= 1
            return retireCurrentLiveWorker(state: &state)
        }
        workersToFinish.forEach { $0.finish() }
    }

    func removeLiveConsumerAndWait() async {
        setLiveConsumer(nil)
        await waitUntilIdle()
    }

    /// consumer を切り離した後、lock 外へ取り出された callback と retired live worker の完了を待つ。
    func waitUntilIdle() async {
        await waitForRouteCallbacks()

        while true {
            let workers = state.withLock { state -> [LiveAudioFrameWorker] in
                state.retiredWorkers
            }
            guard !workers.isEmpty else { return }
            workers.forEach { $0.finish() }
            for worker in workers {
                await worker.waitUntilFinished()
            }
            state.withLock { state in
                state.retiredWorkers.removeAll { retiredWorker in
                    workers.contains { $0 === retiredWorker }
                }
            }
        }
    }

    func route(_ chunk: CapturedAudioChunk) {
        guard let consumers: Consumers = state.withLock({ state in
            guard state.batchConsumer != nil || state.liveWorker != nil else { return nil }
            state.inFlightRouteCount += 1
            return Consumers(batch: state.batchConsumer, liveWorker: state.liveWorker)
        }) else { return }
        defer { finishRoute() }

        consumers.batch?(chunk)
        consumers.liveWorker?.enqueue(chunk)
    }

    private func liveWorkerFailed(generation: UInt64) {
        let result = state.withLock { state -> (workers: [LiveAudioFrameWorker], handler: LiveFailureHandler?) in
            guard state.liveGeneration == generation else { return ([], nil) }
            state.liveGeneration &+= 1
            let handler = state.liveFailureHandler
            let workers = retireCurrentLiveWorker(state: &state)
            return (workers, handler)
        }
        result.workers.forEach { $0.finish() }
        result.handler?()
    }

    private func retireCurrentLiveWorker(state: inout State) -> [LiveAudioFrameWorker] {
        guard let worker = state.liveWorker else {
            state.liveFailureHandler = nil
            return []
        }

        state.liveWorker = nil
        state.liveFailureHandler = nil
        state.retiredWorkers.append(worker)
        if state.inFlightRouteCount > 0 {
            state.workersWaitingForRouteCompletion.append(worker)
            return []
        }
        return [worker]
    }

    private func waitForRouteCallbacks() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard state.inFlightRouteCount > 0 else { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func finishRoute() {
        let result = state.withLock { state -> (
            workers: [LiveAudioFrameWorker],
            waiters: [CheckedContinuation<Void, Never>]
        ) in
            state.inFlightRouteCount -= 1
            guard state.inFlightRouteCount == 0 else { return ([], []) }
            let workers = state.workersWaitingForRouteCompletion
            let waiters = state.idleWaiters
            state.workersWaitingForRouteCompletion.removeAll()
            state.idleWaiters.removeAll()
            return (workers, waiters)
        }
        result.workers.forEach { $0.finish() }
        result.waiters.forEach { $0.resume() }
    }
}
