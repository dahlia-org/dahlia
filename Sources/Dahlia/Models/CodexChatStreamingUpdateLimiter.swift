import Foundation

@MainActor
final class CodexChatStreamingUpdateLimiter {
    private let minimumInterval: Duration
    private let sleep: (Duration) async throws -> Void
    private let publish: () -> Void
    private var lastPublishedAt: ContinuousClock.Instant?
    private var pendingTask: Task<Void, Never>?

    init(
        minimumInterval: Duration = .milliseconds(50),
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        publish: @escaping () -> Void
    ) {
        self.minimumInterval = minimumInterval
        self.sleep = sleep
        self.publish = publish
    }

    func submit(force: Bool = false) {
        let now = ContinuousClock.now
        guard !force, let lastPublishedAt else {
            publishLatest(at: now)
            return
        }

        let nextPublishAt = lastPublishedAt.advanced(by: minimumInterval)
        guard now < nextPublishAt else {
            publishLatest(at: now)
            return
        }
        guard pendingTask == nil else { return }

        let delay = now.duration(to: nextPublishAt)
        let sleep = sleep
        pendingTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.publishLatest(at: .now)
        }
    }

    private func publishLatest(at instant: ContinuousClock.Instant) {
        pendingTask?.cancel()
        pendingTask = nil
        lastPublishedAt = instant
        publish()
    }
}
