import Foundation

protocol BatchSpeechWatchdogClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousBatchSpeechWatchdogClock: BatchSpeechWatchdogClock {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

actor BatchSpeechAnalysisWatchdog {
    typealias TimeoutAction = @Sendable () async -> Void

    private let timeout: Duration
    private let clock: any BatchSpeechWatchdogClock
    private let timeoutAction: TimeoutAction
    private var timerTask: Task<Void, Never>?
    private var generation = 0
    private(set) var didTimeOut = false

    init(
        timeout: Duration,
        clock: any BatchSpeechWatchdogClock = ContinuousBatchSpeechWatchdogClock(),
        timeoutAction: @escaping TimeoutAction
    ) {
        self.timeout = timeout
        self.clock = clock
        self.timeoutAction = timeoutAction
    }

    func start() {
        recordProgress()
    }

    func recordProgress() {
        guard !didTimeOut else { return }
        generation += 1
        let expectedGeneration = generation
        timerTask?.cancel()
        let timeout = timeout
        let clock = clock
        timerTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
                guard let timeoutAction = await self?.markTimedOut(ifGenerationIs: expectedGeneration) else {
                    return
                }
                await timeoutAction()
                await self?.finishTimeoutAction(ifGenerationIs: expectedGeneration)
            } catch {
                return
            }
        }
    }

    func stop() {
        generation += 1
        timerTask?.cancel()
        timerTask = nil
    }

    private func markTimedOut(ifGenerationIs expectedGeneration: Int) -> TimeoutAction? {
        guard generation == expectedGeneration, !didTimeOut else { return nil }
        didTimeOut = true
        return timeoutAction
    }

    private func finishTimeoutAction(ifGenerationIs expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        timerTask = nil
    }
}
