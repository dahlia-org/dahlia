import Foundation
import GRDB
@testable import Dahlia
@preconcurrency import ScreenCaptureKit

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
    func staleProcessingCompletionPreservesReplacementOperationAndPendingFrame() throws {
        var state = AutomaticScreenshotProcessingState()
        let staleAttempt = AutomaticScreenshotCaptureAttempt(generation: 1, id: 1)
        let replacementAttempt = AutomaticScreenshotCaptureAttempt(generation: 2, id: 2)
        state.begin(attempt: staleAttempt) { _ in Task {} }
        _ = state.queueLatest(
            makeFrame(byte: 1, capturedAt: Date(timeIntervalSince1970: 100)),
            attempt: staleAttempt
        )
        let staleOperationResult = state.take(matching: staleAttempt)
        let staleOperation = try #require(staleOperationResult)

        state.begin(attempt: replacementAttempt) { _ in Task {} }
        let replacementDate = Date(timeIntervalSince1970: 200)
        let queuedReplacement = state.queueLatest(
            makeFrame(byte: 2, capturedAt: replacementDate),
            attempt: replacementAttempt
        )
        #expect(queuedReplacement)
        let stalePending = state.complete(
            operationID: staleOperation.id,
            attempt: staleAttempt
        )

        #expect(stalePending == nil)
        #expect(state.operation?.attempt == replacementAttempt)
        #expect(state.pendingFrame?.attempt == replacementAttempt)
        #expect(state.pendingFrame?.frame.capturedAt == replacementDate)
    }

    @Test
    func frameMailboxRetainsOnlyTheNewestPendingFullResolutionFrame() async throws {
        let mailbox = AutomaticScreenshotFrameMailbox()
        let firstDate = Date(timeIntervalSince1970: 100)
        let latestDate = Date(timeIntervalSince1970: 300)
        mailbox.yield(makeFrame(byte: 1, capturedAt: firstDate))
        mailbox.yield(makeFrame(byte: 2, capturedAt: Date(timeIntervalSince1970: 200)))
        mailbox.yield(makeFrame(byte: 3, capturedAt: latestDate))
        mailbox.finish()

        var iterator = mailbox.stream.makeAsyncIterator()
        let received = try #require(await iterator.next())
        #expect(received.pixels == Data(repeating: 3, count: 4))
        #expect(received.capturedAt == latestDate)
        #expect(await iterator.next() == nil)
    }

    @Test
    func persistedRecordUsesFrameReceiptTime() {
        let capturedAt = Date(timeIntervalSince1970: 123)
        let frame = makeFrame(byte: 1, capturedAt: capturedAt)
        let record = AutomaticScreenshotCaptureService.makeRecord(
            frame: frame,
            meetingID: .v7(),
            sessionID: .v7(),
            encodedData: Data([9]),
            mimeType: "image/jpeg"
        )

        #expect(record.capturedAt == capturedAt)
    }

    @Test
    func sourcePixelDimensionsRecoverNativeSizeFromScaledSurface() throws {
        let dimensions = try #require(AutomaticScreenshotCaptureService.sourcePixelDimensions(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            contentScale: 0.5,
            scaleFactor: 2
        ))

        #expect(dimensions == AutomaticScreenshotPixelDimensions(width: 2_400, height: 1_600))
        #expect(AutomaticScreenshotCaptureService.sourcePixelDimensions(
            contentRect: .zero,
            contentScale: 1,
            scaleFactor: 2
        ) == nil)
    }

    @Test
    func sourcePixelDimensionsDecodeDictionaryContentRect() throws {
        let contentRect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let attachments: [SCStreamFrameInfo: Any] = [
            .contentRect: contentRect.dictionaryRepresentation,
            .contentScale: CGFloat(0.5),
            .scaleFactor: CGFloat(2),
        ]

        let dimensions = try #require(AutomaticScreenshotCaptureService.sourcePixelDimensions(
            from: attachments
        ))

        #expect(dimensions == AutomaticScreenshotPixelDimensions(width: 2_400, height: 1_600))
    }

    @Test
    func sourcePixelDimensionsDecodeDirectContentRectAndRejectInvalidMetadata() throws {
        let directAttachments: [SCStreamFrameInfo: Any] = [
            .contentRect: CGRect(x: 0, y: 0, width: 1_358, height: 1_219),
            .contentScale: CGFloat(1),
            .scaleFactor: CGFloat(1),
        ]
        let dimensions = try #require(AutomaticScreenshotCaptureService.sourcePixelDimensions(
            from: directAttachments
        ))

        #expect(dimensions == AutomaticScreenshotPixelDimensions(width: 1_358, height: 1_219))
        #expect(AutomaticScreenshotCaptureService.sourcePixelDimensions(from: [
            .contentRect: "invalid",
            .contentScale: CGFloat(1),
            .scaleFactor: CGFloat(1),
        ]) == nil)
        #expect(AutomaticScreenshotCaptureService.sourcePixelDimensions(from: [
            .contentRect: CGRect(x: 0, y: 0, width: 1_358, height: 1_219).dictionaryRepresentation,
            .contentScale: CGFloat(0),
            .scaleFactor: CGFloat(1),
        ]) == nil)
    }

    @Test
    func resolutionActionUpdatesThenDiscardsStaleSurfaceBeforeProcessingNativeFrame() {
        let staleDimensions = AutomaticScreenshotPixelDimensions(width: 1_104, height: 932)
        let nativeDimensions = AutomaticScreenshotPixelDimensions(width: 1_358, height: 1_219)

        #expect(AutomaticScreenshotCaptureService.frameResolutionAction(
            frameDimensions: staleDimensions,
            sourcePixelDimensions: nativeDimensions,
            configuredDimensions: staleDimensions
        ) == .updateConfiguration(nativeDimensions))
        #expect(AutomaticScreenshotCaptureService.frameResolutionAction(
            frameDimensions: staleDimensions,
            sourcePixelDimensions: nativeDimensions,
            configuredDimensions: nativeDimensions
        ) == .discard)
        #expect(AutomaticScreenshotCaptureService.frameResolutionAction(
            frameDimensions: staleDimensions,
            sourcePixelDimensions: staleDimensions,
            configuredDimensions: nativeDimensions
        ) == .discard)
        #expect(AutomaticScreenshotCaptureService.frameResolutionAction(
            frameDimensions: nativeDimensions,
            sourcePixelDimensions: nativeDimensions,
            configuredDimensions: nativeDimensions
        ) == .process)
        #expect(AutomaticScreenshotCaptureService.frameResolutionAction(
            frameDimensions: staleDimensions,
            sourcePixelDimensions: nil,
            configuredDimensions: nativeDimensions
        ) == .discard)
        #expect(AutomaticScreenshotCaptureService.frameResolutionAction(
            frameDimensions: nativeDimensions,
            sourcePixelDimensions: nil,
            configuredDimensions: nativeDimensions
        ) == .process)
    }

    @Test
    func resolutionUpdateDiscardsPendingFrameWithoutRemovingActiveOperation() {
        var state = AutomaticScreenshotProcessingState()
        let attempt = AutomaticScreenshotCaptureAttempt(generation: 1, id: 1)
        state.begin(attempt: attempt) { _ in Task {} }
        let didQueuePendingFrame = state.queueLatest(
            makeFrame(byte: 1, capturedAt: Date(timeIntervalSince1970: 100)),
            attempt: attempt
        )
        #expect(didQueuePendingFrame)

        state.discardPendingFrame(matching: attempt)

        #expect(state.operation?.attempt == attempt)
        #expect(state.pendingFrame == nil)
    }

    @Test
    @MainActor
    func stopBypassesBlockedStartAndInvalidatesPendingSettings() async throws {
        let capture = BlockingAutomaticScreenshotCapture()
        let control = AutomaticScreenshotCaptureControl(capture: capture)
        let request = AutomaticScreenshotCaptureRequest(
            source: .entireDesktop,
            intervalSeconds: 5,
            changeThresholdRatio: 0.20,
            meetingID: .v7(),
            sessionID: .v7(),
            dbQueue: try DatabaseQueue(),
            onPersisted: { _ in },
            onFailure: { _ in }
        )
        let startTask = control.enqueue { capture in
            await capture.start(request)
        }
        await capture.waitUntilStartBegins()
        let settingsTask = control.enqueue { capture in
            await capture.updateSettings(intervalSeconds: 10, changeThresholdRatio: 0.30)
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
        #expect(ErrorReportingService.automaticScreenshotDurationBucket(1_000) == 1_000)
        #expect(ErrorReportingService.automaticScreenshotDurationBucket(2_500) == 2_000)
        #expect(ErrorReportingService.automaticScreenshotDurationBucket(8_000) == 5_000)
    }

    private func makeFrame(byte: UInt8, capturedAt: Date) -> CopiedScreenshotFrame {
        CopiedScreenshotFrame(
            width: 1,
            height: 1,
            bytesPerRow: 4,
            pixels: Data(repeating: byte, count: 4),
            capturedAt: capturedAt
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

    func updateSettings(intervalSeconds _: Int, changeThresholdRatio _: Double) {
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
