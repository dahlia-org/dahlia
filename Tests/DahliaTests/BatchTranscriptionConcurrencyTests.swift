import Foundation
import Speech
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchTranscriptionConcurrencyTests {
        @Test
        func languageDetectionIsSerializedAcrossConcurrentRequests() async throws {
            let detector = SuspendingLanguageDetector()
            defer { Task { await detector.resumeAll() } }
            let serialized = SerializedBatchLanguageDetector(detector: detector)
            let firstURL = URL(fileURLWithPath: "/tmp/first.caf")
            let secondURL = URL(fileURLWithPath: "/tmp/second.caf")

            async let first = serialized.detectLanguage(audioURL: firstURL)
            async let second = serialized.detectLanguage(audioURL: secondURL)

            try await waitUntil { await detector.callCount == 1 }
            #expect(await detector.maximumActiveCount == 1)
            await detector.resumeNext()
            try await waitUntil { await detector.callCount == 2 }
            #expect(await detector.maximumActiveCount == 1)
            await detector.resumeNext()

            _ = try await (first, second)
            #expect(await detector.maximumActiveCount == 1)
        }

        @Test
        func cancelledLimiterWaiterLeavesQueueWithoutWaitingForActiveOperation() async throws {
            let limiter = BatchTranscriptionConcurrencyLimiter(limit: 1)
            let probe = ConcurrencyLimiterProbe()
            defer { Task { await probe.resume() } }
            let active = Task {
                try await limiter.perform {
                    await probe.hold()
                }
            }
            try await waitUntil { await probe.didStart }
            let waiting = Task {
                try await limiter.perform {
                    await probe.recordUnexpectedOperation()
                }
            }
            await Task.yield()

            waiting.cancel()
            await #expect(throws: CancellationError.self) {
                try await waiting.value
            }
            #expect(await !probe.didRunUnexpectedOperation)

            await probe.resume()
            try await active.value
        }

        @Test
        func appleRecognitionAllowsFourConcurrentRequests() async throws {
            let recognizer = SuspendingSpeechRecognizer()
            defer { Task { await recognizer.resumeAll() } }
            let adaptive = AdaptiveBatchSpeechRecognizer(recognizer: recognizer)
            let locale = Locale(identifier: "ja_JP")

            async let first = adaptive.recognize(audioURL: URL(fileURLWithPath: "/tmp/first.caf"), locale: locale)
            async let second = adaptive.recognize(audioURL: URL(fileURLWithPath: "/tmp/second.caf"), locale: locale)
            async let third = adaptive.recognize(audioURL: URL(fileURLWithPath: "/tmp/third.caf"), locale: locale)
            async let fourth = adaptive.recognize(audioURL: URL(fileURLWithPath: "/tmp/fourth.caf"), locale: locale)
            async let fifth = adaptive.recognize(audioURL: URL(fileURLWithPath: "/tmp/fifth.caf"), locale: locale)

            try await waitUntil { await recognizer.callCount == 4 }
            #expect(await recognizer.maximumActiveCount == 4)
            await recognizer.resumeNext()
            try await waitUntil { await recognizer.callCount == 5 }
            #expect(await recognizer.maximumActiveCount == 4)
            await recognizer.resumeAll()
            _ = try await (first, second, third, fourth, fifth)
        }

        @Test
        func insufficientResourcesReducesConcurrencyAndRetriesOnce() async throws {
            let recognizer = ResourceLimitedSpeechRecognizer(failureCount: 1)
            let adaptive = AdaptiveBatchSpeechRecognizer(recognizer: recognizer)

            _ = try await adaptive.recognize(
                audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                locale: Locale(identifier: "ja_JP")
            )

            #expect(await recognizer.callCount == 2)
            #expect(await adaptive.currentConcurrencyLimit() == 1)
        }

        @Test
        func persistentInsufficientResourcesIsNotRetriedMoreThanOnce() async {
            let recognizer = ResourceLimitedSpeechRecognizer(failureCount: 2)
            let adaptive = AdaptiveBatchSpeechRecognizer(recognizer: recognizer)

            await #expect(throws: NSError.self) {
                _ = try await adaptive.recognize(
                    audioURL: URL(fileURLWithPath: "/tmp/audio.caf"),
                    locale: Locale(identifier: "ja_JP")
                )
            }
            #expect(await recognizer.callCount == 2)
        }

        @Test
        func insufficientResourcesWaitsForInflightRecognitionThenKeepsSerialLimit() async throws {
            let recognizer = ConcurrentResourceLimitedSpeechRecognizer()
            defer { Task { await recognizer.resumeAll() } }
            let adaptive = AdaptiveBatchSpeechRecognizer(recognizer: recognizer)
            let locale = Locale(identifier: "ja_JP")

            let held = Task {
                try await adaptive.recognize(
                    audioURL: URL(fileURLWithPath: "/tmp/held.caf"),
                    locale: locale
                )
            }
            try await waitUntil { await recognizer.activeCount == 1 }
            let fallback = Task {
                try await adaptive.recognize(
                    audioURL: URL(fileURLWithPath: "/tmp/fallback.caf"),
                    locale: locale
                )
            }
            try await waitUntil { await recognizer.didReturnResourceFailure }
            await Task.yield()
            #expect(await recognizer.callCount == 2)

            await recognizer.resumeNext()
            _ = try await held.value
            _ = try await fallback.value
            #expect(await recognizer.callCount == 3)
            #expect(await adaptive.currentConcurrencyLimit() == 1)

            let nextA = Task {
                try await adaptive.recognize(audioURL: URL(fileURLWithPath: "/tmp/next-a.caf"), locale: locale)
            }
            let nextB = Task {
                try await adaptive.recognize(audioURL: URL(fileURLWithPath: "/tmp/next-b.caf"), locale: locale)
            }
            try await waitUntil { await recognizer.callCount == 4 }
            #expect(await recognizer.activeCount == 1)
            await recognizer.resumeNext()
            try await waitUntil { await recognizer.callCount == 5 }
            #expect(await recognizer.activeCount == 1)
            await recognizer.resumeNext()
            _ = try await (nextA.value, nextB.value)

            await adaptive.unload()
            #expect(await adaptive.currentConcurrencyLimit() == 4)
        }

        @Test
        func speechAssetPreparationCoalescesWaitersAndCancelledWaiterLeavesImmediately() async throws {
            let probe = SpeechAssetPreparationProbe()
            defer { Task { await probe.resumeFirstPreparation() } }
            let preparer = AppleSpeechAssetPreparer { _ in
                try await probe.prepare()
            }
            let transcriber = SpeechTranscriber(locale: Locale(identifier: "ja_JP"), preset: .transcription)

            let first = Task {
                try await preparer.prepare(transcriber: transcriber, localeIdentifier: "ja_JP")
            }
            try await waitUntil { await probe.callCount == 1 }
            let second = Task {
                try await preparer.prepare(transcriber: transcriber, localeIdentifier: "ja_JP")
            }
            await Task.yield()

            first.cancel()
            await #expect(throws: CancellationError.self) {
                try await first.value
            }
            #expect(await probe.callCount == 1)

            await probe.resumeFirstPreparation()
            try await second.value

            try await preparer.prepare(transcriber: transcriber, localeIdentifier: "ja_JP")
            #expect(await probe.callCount == 1)
            await preparer.reset()
            try await preparer.prepare(transcriber: transcriber, localeIdentifier: "ja_JP")
            #expect(await probe.callCount == 2)
        }

        @Test
        func resettingSpeechAssetsCancelsInflightPreparationAndDoesNotRecacheIt() async throws {
            let probe = SpeechAssetPreparationProbe()
            defer { Task { await probe.resumeFirstPreparation() } }
            let preparer = AppleSpeechAssetPreparer { _ in
                try await probe.prepare()
            }
            let transcriber = SpeechTranscriber(locale: Locale(identifier: "ja_JP"), preset: .transcription)
            let first = Task {
                try await preparer.prepare(transcriber: transcriber, localeIdentifier: "ja_JP")
            }
            try await waitUntil { await probe.callCount == 1 }

            await preparer.reset()
            await #expect(throws: CancellationError.self) {
                try await first.value
            }
            try await preparer.prepare(transcriber: transcriber, localeIdentifier: "ja_JP")
            #expect(await probe.callCount == 2)
        }

        private func waitUntil(
            timeout: Duration = .seconds(5),
            condition: @escaping @Sendable () async -> Bool
        ) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while await !condition() {
                guard ContinuousClock.now < deadline else {
                    throw ConcurrencyTestError.timedOut
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private enum ConcurrencyTestError: Error {
        case timedOut
    }

    private actor ConcurrencyLimiterProbe {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var didStart = false
        private(set) var didRunUnexpectedOperation = false

        func hold() async {
            didStart = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func recordUnexpectedOperation() {
            didRunUnexpectedOperation = true
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor SuspendingLanguageDetector: BatchLanguageDetecting {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private(set) var callCount = 0
        private(set) var maximumActiveCount = 0
        private var activeCount = 0

        func detectLanguage(
            audioURL _: URL,
            allowedLanguageIdentifiers _: Set<String>?
        ) async -> BatchLanguageDetectionOutcome {
            callCount += 1
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
            activeCount -= 1
            return .confidentDetection("ja")
        }

        func resumeNext() {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume()
        }

        func resumeAll() {
            let pending = continuations
            continuations.removeAll()
            for continuation in pending {
                continuation.resume()
            }
        }

        func unload() async {}
    }

    private actor SuspendingSpeechRecognizer: BatchSpeechRecognizing {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private(set) var callCount = 0
        private(set) var maximumActiveCount = 0
        private var activeCount = 0

        func recognize(audioURL _: URL, locale _: Locale) async -> [BatchSpeechRecognition] {
            callCount += 1
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
            activeCount -= 1
            return []
        }

        func resumeAll() {
            let pending = continuations
            continuations.removeAll()
            for continuation in pending {
                continuation.resume()
            }
        }

        func resumeNext() {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume()
        }
    }

    private actor ResourceLimitedSpeechRecognizer: BatchSpeechRecognizing {
        private var remainingFailureCount: Int
        private(set) var callCount = 0

        init(failureCount: Int) {
            remainingFailureCount = failureCount
        }

        func recognize(audioURL _: URL, locale _: Locale) throws -> [BatchSpeechRecognition] {
            callCount += 1
            if remainingFailureCount > 0 {
                remainingFailureCount -= 1
                throw NSError(
                    domain: SFSpeechErrorDomain,
                    code: SFSpeechError.Code.insufficientResources.rawValue
                )
            }
            return []
        }
    }

    private actor SpeechAssetPreparationProbe {
        private var firstContinuation: CheckedContinuation<Void, Never>?
        private(set) var callCount = 0

        func prepare() async throws {
            callCount += 1
            guard callCount == 1 else { return }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    firstContinuation = continuation
                }
            } onCancel: {
                Task { await self.resumeFirstPreparation() }
            }
            try Task.checkCancellation()
        }

        func resumeFirstPreparation() {
            firstContinuation?.resume()
            firstContinuation = nil
        }
    }

    private actor ConcurrentResourceLimitedSpeechRecognizer: BatchSpeechRecognizing {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private(set) var callCount = 0
        private(set) var activeCount = 0
        private(set) var didReturnResourceFailure = false
        private var resourceFailureRemaining = true

        func recognize(audioURL: URL, locale _: Locale) async throws -> [BatchSpeechRecognition] {
            callCount += 1
            activeCount += 1
            defer { activeCount -= 1 }

            if audioURL.lastPathComponent == "fallback.caf", resourceFailureRemaining {
                resourceFailureRemaining = false
                didReturnResourceFailure = true
                throw NSError(
                    domain: SFSpeechErrorDomain,
                    code: SFSpeechError.Code.insufficientResources.rawValue
                )
            }
            if audioURL.lastPathComponent != "fallback.caf" {
                await withCheckedContinuation { continuation in
                    continuations.append(continuation)
                }
            }
            return []
        }

        func resumeNext() {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume()
        }

        func resumeAll() {
            let pending = continuations
            continuations.removeAll()
            for continuation in pending {
                continuation.resume()
            }
        }
    }
#endif
