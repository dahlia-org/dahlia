import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct AutomaticScreenshotCaptureServiceTests {
        @Test
        func lifecycleRejectsFramesFromStoppedAndReplacedStreams() throws {
            var lifecycle = AutomaticScreenshotCaptureLifecycle()

            let firstGenerationResult = lifecycle.begin()
            let firstGeneration = try #require(firstGenerationResult)
            #expect(lifecycle.accepts(generation: firstGeneration))

            lifecycle.stop()
            #expect(!lifecycle.accepts(generation: firstGeneration))

            let secondGenerationResult = lifecycle.begin()
            let secondGeneration = try #require(secondGenerationResult)
            #expect(secondGeneration != firstGeneration)
            #expect(!lifecycle.accepts(generation: firstGeneration))
            #expect(lifecycle.accepts(generation: secondGeneration))
        }

        @Test
        func lifecycleAllowsOnlyOneCompletionOwnerPerStreamAttempt() throws {
            var lifecycle = AutomaticScreenshotCaptureLifecycle()
            let generationResult = lifecycle.begin()
            let generation = try #require(generationResult)
            let firstAttemptResult = lifecycle.beginAttempt(generation: generation)
            let firstAttempt = try #require(firstAttemptResult)

            let overlappingAttempt = lifecycle.beginAttempt(generation: generation)
            let firstClaim = lifecycle.claimCompletion(attempt: firstAttempt)
            let duplicateClaim = lifecycle.claimCompletion(attempt: firstAttempt)
            #expect(overlappingAttempt == nil)
            #expect(firstClaim)
            #expect(!duplicateClaim)
            #expect(!lifecycle.accepts(attempt: firstAttempt))

            lifecycle.finishAttempt(firstAttempt)
            let retryAttemptResult = lifecycle.beginAttempt(generation: generation)
            let retryAttempt = try #require(retryAttemptResult)
            #expect(retryAttempt != firstAttempt)
            #expect(lifecycle.accepts(attempt: retryAttempt))
        }

        @Test
        func replacementStartRejectsAnEarlierStartResumingAfterCleanup() throws {
            var lifecycle = AutomaticScreenshotCaptureLifecycle()
            let staleGeneration = lifecycle.beginReplacement()
            let staleAttemptResult = lifecycle.beginAttempt(generation: staleGeneration)
            let staleAttempt = try #require(staleAttemptResult)

            let replacementGeneration = lifecycle.beginReplacement()
            let replacementAttemptResult = lifecycle.beginAttempt(generation: replacementGeneration)
            let replacementAttempt = try #require(replacementAttemptResult)
            lifecycle.finishAttempt(staleAttempt)

            #expect(!lifecycle.accepts(generation: staleGeneration))
            #expect(!lifecycle.accepts(attempt: staleAttempt))
            #expect(lifecycle.accepts(generation: replacementGeneration))
            #expect(lifecycle.accepts(attempt: replacementAttempt))
        }

        @Test
        func staleProcessingCompletionPreservesReplacementOperation() throws {
            var state = AutomaticScreenshotProcessingState()
            let staleAttempt = AutomaticScreenshotCaptureAttempt(generation: 1, id: 1)
            let replacementAttempt = AutomaticScreenshotCaptureAttempt(generation: 2, id: 2)
            state.begin(attempt: staleAttempt) { _ in Task {} }
            let staleOperationResult = state.take(matching: staleAttempt)
            let staleOperation = try #require(staleOperationResult)

            state.begin(attempt: replacementAttempt) { _ in Task {} }
            let completedStale = state.complete(
                operationID: staleOperation.id,
                attempt: staleAttempt
            )

            #expect(!completedStale)
            #expect(state.operation?.attempt == replacementAttempt)
        }

        @Test
        func frameMailboxRetainsOnlyTheNewestPendingDetectionFrame() async throws {
            let mailbox = AutomaticScreenshotFrameMailbox()
            mailbox.yield(makeFrame(byte: 1))
            mailbox.yield(makeFrame(byte: 2))
            mailbox.yield(makeFrame(byte: 3))
            mailbox.finish()

            var iterator = mailbox.stream.makeAsyncIterator()
            let received = try #require(await iterator.next())
            #expect(received.pixels == Data(repeating: 3, count: 4))
            #expect(await iterator.next() == nil)
        }

        @Test
        func persistedRecordUsesCaptureTime() {
            let capturedAt = Date(timeIntervalSince1970: 123)
            let record = AutomaticScreenshotCaptureService.makeRecord(
                capturedAt: capturedAt,
                meetingID: .v7(),
                sessionID: .v7(),
                encodedData: Data([9]),
                mimeType: "image/jpeg"
            )

            #expect(record.capturedAt == capturedAt)
        }

        @Test
        func onlySavedOrSkippedCapturesCommitTheReference() {
            #expect(AutomaticScreenshotCaptureOutcome.saved.commitsReference)
            #expect(AutomaticScreenshotCaptureOutcome.skipped.commitsReference)
            #expect(!AutomaticScreenshotCaptureOutcome.discarded.commitsReference)
            #expect(!AutomaticScreenshotCaptureOutcome.failed.commitsReference)
        }

        @Test
        func stalePersistenceDoesNotRestoreResetFingerprintBaseline() {
            let oldFingerprint = ScreenshotFingerprint(width: 1, height: 1, pixels: [1])
            var baseline = AutomaticScreenshotFingerprintBaseline()
            baseline.record(oldFingerprint, detectionScopeMatches: true)

            baseline.reset()
            baseline.record(oldFingerprint, detectionScopeMatches: false)

            #expect(baseline.value == nil)
        }

        @Test
        @MainActor
        func stopBypassesBlockedStartAndInvalidatesPendingSettings() async throws {
            let capture = BlockingAutomaticScreenshotCapture()
            let control = AutomaticScreenshotCaptureControl(capture: capture)
            let request = try AutomaticScreenshotCaptureRequest(
                source: .entireDesktop,
                intervalSeconds: 5,
                changeThresholdRatio: 0.20,
                detectsChangesInSharedContentOnly: false,
                cropsToSharedContent: false,
                meetingID: .v7(),
                sessionID: .v7(),
                dbQueue: DatabaseQueue(),
                onPersisted: { _ in },
                onFailure: { _ in }
            )
            let startTask = control.enqueue { capture in
                await capture.start(request)
            }
            await capture.waitUntilStartBegins()
            let settingsTask = control.enqueue { capture in
                await capture.updateSettings(
                    intervalSeconds: 10,
                    changeThresholdRatio: 0.30,
                    detectsChangesInSharedContentOnly: true,
                    cropsToSharedContent: true
                )
            }

            let stopTask = control.stop()
            var stopBypassedStart = false
            for _ in 0 ..< 100 {
                if await capture.stopCount() == 1 {
                    stopBypassedStart = true
                    break
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(stopBypassedStart)

            await capture.resumeStart()
            await startTask.value
            await settingsTask.value
            await stopTask.value
            #expect(await capture.settingsUpdateCount() == 0)
        }

        @Test
        func slowStageDurationsUseBoundedBuckets() {
            #expect(ErrorReportingService.automaticScreenshotDurationBucket(500) == 500)
            #expect(ErrorReportingService.automaticScreenshotDurationBucket(999) == 500)
            #expect(ErrorReportingService.automaticScreenshotDurationBucket(1000) == 1000)
            #expect(ErrorReportingService.automaticScreenshotDurationBucket(2500) == 2000)
            #expect(ErrorReportingService.automaticScreenshotDurationBucket(8000) == 5000)
        }

        private func makeFrame(byte: UInt8) -> CopiedScreenshotFrame {
            CopiedScreenshotFrame(
                width: 1,
                height: 1,
                bytesPerRow: 4,
                pixels: Data(repeating: byte, count: 4)
            )
        }
    }

    private actor BlockingAutomaticScreenshotCapture: AutomaticScreenshotCapturing {
        private var startContinuation: CheckedContinuation<Void, Never>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var didBeginStart = false
        private var observedStopCount = 0
        private var observedSettingsUpdateCount = 0

        func start(_: AutomaticScreenshotCaptureRequest) async {
            didBeginStart = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }

        func updateSettings(
            intervalSeconds _: Int,
            changeThresholdRatio _: Double,
            detectsChangesInSharedContentOnly _: Bool,
            cropsToSharedContent _: Bool
        ) {
            observedSettingsUpdateCount += 1
        }

        func stop() {
            observedStopCount += 1
        }

        func waitUntilStartBegins() async {
            guard !didBeginStart else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func resumeStart() {
            startContinuation?.resume()
            startContinuation = nil
        }

        func stopCount() -> Int {
            observedStopCount
        }

        func settingsUpdateCount() -> Int {
            observedSettingsUpdateCount
        }
    }
#endif
