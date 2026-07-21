import Foundation
import Speech

enum BatchTranscriptionConcurrency {
    static let appleSpeechMaximum = 4
}

actor BatchTranscriptionConcurrencyLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func perform<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    func performWithoutCancellation<T: Sendable>(
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        await acquireWithoutCancellation()
        defer { release() }
        return await operation()
    }

    func reduceLimit(to newLimit: Int) {
        limit = min(limit, max(1, newLimit))
        resumeWaitersIfPossible()
    }

    func resetLimit(to newLimit: Int) {
        limit = max(1, newLimit)
        resumeWaitersIfPossible()
    }

    func currentLimit() -> Int {
        limit
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            return
        }
        let id = UUID.v7()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func acquireWithoutCancellation() async {
        if activeCount < limit {
            activeCount += 1
            return
        }
        let id = UUID.v7()
        // This path is reserved for cleanup. It must reach the underlying unload even when
        // the queue processor itself was cancelled.
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    private func release() {
        activeCount = max(0, activeCount - 1)
        resumeWaitersIfPossible()
    }

    private func resumeWaitersIfPossible() {
        while activeCount < limit, !waiters.isEmpty {
            activeCount += 1
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Keeps WhisperKit decoder access serialized while allowing the surrounding CAF pipeline to overlap work.
struct SerializedBatchLanguageDetector: BatchLanguageDetecting {
    private let detector: any BatchLanguageDetecting
    private let limiter = BatchTranscriptionConcurrencyLimiter(limit: 1)

    init(detector: any BatchLanguageDetecting) {
        self.detector = detector
    }

    func detectLanguage(
        audioURL: URL,
        allowedLanguageIdentifiers: Set<String>? = nil
    ) async throws -> BatchLanguageDetectionOutcome {
        try await limiter.perform {
            try await detector.detectLanguage(
                audioURL: audioURL,
                allowedLanguageIdentifiers: allowedLanguageIdentifiers
            )
        }
    }

    func unload() async {
        await limiter.performWithoutCancellation {
            await detector.unload()
        }
    }
}

/// Uses up to four Apple Speech analyzers until the framework reports resource exhaustion, then retries serially.
struct AdaptiveBatchSpeechRecognizer: BatchSpeechRecognizing {
    private let recognizer: any BatchSpeechRecognizing
    private let limiter = BatchTranscriptionConcurrencyLimiter(limit: BatchTranscriptionConcurrency.appleSpeechMaximum)

    init(recognizer: any BatchSpeechRecognizing) {
        self.recognizer = recognizer
    }

    func recognize(audioURL: URL, locale: Locale) async throws -> [BatchSpeechRecognition] {
        do {
            return try await performRecognition(audioURL: audioURL, locale: locale)
        } catch where Self.isInsufficientResources(error) {
            await limiter.reduceLimit(to: 1)
            try Task.checkCancellation()
            return try await performRecognition(audioURL: audioURL, locale: locale)
        }
    }

    func currentConcurrencyLimit() async -> Int {
        await limiter.currentLimit()
    }

    func unload() async {
        await limiter.performWithoutCancellation {
            await recognizer.unload()
        }
        await limiter.resetLimit(to: BatchTranscriptionConcurrency.appleSpeechMaximum)
    }

    private func performRecognition(audioURL: URL, locale: Locale) async throws -> [BatchSpeechRecognition] {
        try await limiter.perform {
            try await recognizer.recognize(audioURL: audioURL, locale: locale)
        }
    }

    private static func isInsufficientResources(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SFSpeechErrorDomain
            && error.code == SFSpeechError.Code.insufficientResources.rawValue
    }
}
