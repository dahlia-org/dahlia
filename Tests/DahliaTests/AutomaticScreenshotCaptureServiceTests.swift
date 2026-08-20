import CoreGraphics
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct AutomaticScreenshotCaptureServiceTests {
        @Test
        func lifecycleRejectsStoppedAndReplacedCaptureGenerations() {
            var lifecycle = AutomaticScreenshotCaptureLifecycle()

            let firstGeneration = lifecycle.beginReplacement()
            #expect(lifecycle.accepts(generation: firstGeneration))

            let replacementGeneration = lifecycle.beginReplacement()
            #expect(!lifecycle.accepts(generation: firstGeneration))
            #expect(lifecycle.accepts(generation: replacementGeneration))

            lifecycle.stop()
            #expect(!lifecycle.accepts(generation: replacementGeneration))
        }

        @Test
        func failedOneShotCaptureRetriesAfterTheConfiguredInterval() async throws {
            let captureProbe = CaptureProbe()
            let sleeper = ControlledSleeper()
            let failures = FailureProbe()
            let service = AutomaticScreenshotCaptureService(
                captureImage: { _ in try await captureProbe.fail() },
                sleep: { duration in try await sleeper.sleep(duration) }
            )

            await service.start(try makeRequest(onFailure: { error in
                failures.record(error)
            }))
            await failures.wait(for: 1)
            await sleeper.wait(for: 1)
            #expect(await captureProbe.count == 1)
            #expect(await sleeper.recordedDurations == [.seconds(5)])

            await sleeper.resumeNext()
            await failures.wait(for: 2)
            #expect(await captureProbe.count == 2)

            await service.stop()
            await sleeper.resumeAll()
        }

        @Test
        func settingsChangeReplacesThePendingIntervalWithoutAnImmediateCapture() async throws {
            let captureProbe = CaptureProbe()
            let sleeper = ControlledSleeper()
            let failures = FailureProbe()
            let service = AutomaticScreenshotCaptureService(
                captureImage: { _ in try await captureProbe.fail() },
                sleep: { duration in try await sleeper.sleep(duration) }
            )

            await service.start(try makeRequest(onFailure: { error in
                failures.record(error)
            }))
            await failures.wait(for: 1)
            await sleeper.wait(for: 1)

            await service.updateSettings(intervalSeconds: 10, changeThresholdRatio: 0.30)
            await sleeper.wait(for: 2)
            #expect(await sleeper.recordedDurations == [.seconds(5), .seconds(10)])
            #expect(await captureProbe.count == 1)

            await sleeper.resumeAll()
            await failures.wait(for: 2)
            #expect(await captureProbe.count == 2)

            await service.stop()
            await sleeper.resumeAll()
        }

        @Test
        func stopInvalidatesAStaleCaptureWithoutWaitingForItToFinish() async throws {
            let capture = BlockingCapture()
            let persisted = PersistenceProbe()
            let service = AutomaticScreenshotCaptureService(
                captureImage: { _ in try await capture.capture() },
                sleep: { duration in try await Task.sleep(for: duration) }
            )

            await service.start(try makeRequest(onPersisted: { _ in
                persisted.record()
            }))
            await capture.waitUntilStarted()

            await service.stop()
            await capture.waitUntilCancelled()
            #expect(!persisted.didPersist)

            await capture.resume(try makeCaptureOutput())
        }

        @Test
        func replacementAfterStopWaitsForAnUnfinishedCapture() async throws {
            let capture = BlockingCapture()
            let service = AutomaticScreenshotCaptureService(
                captureImage: { _ in try await capture.capture() },
                sleep: { duration in try await Task.sleep(for: duration) }
            )
            let request = try makeRequest()

            await service.start(request)
            await capture.wait(for: 1)
            await service.stop()
            await service.start(request)
            await Task.yield()
            #expect(await capture.maximumActiveCount == 1)

            await capture.resume(try makeCaptureOutput())
            await capture.wait(for: 2)
            #expect(await capture.maximumActiveCount == 1)

            await service.stop()
        }

        @Test(.timeLimit(.minutes(1)))
        func settingsIntervalElapsesWhileWaitingForAnUnfinishedCapture() async throws {
            let capture = BlockingCapture()
            let sleeper = ControlledSleeper()
            let service = AutomaticScreenshotCaptureService(
                captureImage: { _ in try await capture.capture() },
                sleep: { duration in try await sleeper.sleep(duration) }
            )

            await service.start(try makeRequest())
            await capture.wait(for: 1)
            await sleeper.wait(for: 1)
            await service.updateSettings(intervalSeconds: 10, changeThresholdRatio: 0.30)
            await sleeper.wait(for: 2)
            #expect(await sleeper.recordedDurations == [.seconds(5), .seconds(10)])

            await sleeper.resumeAll()
            await capture.resume(try makeCaptureOutput())
            await capture.wait(for: 2)
            #expect(await capture.maximumActiveCount == 1)

            await service.stop()
            await sleeper.resumeAll()
        }

        @Test
        func persistedRecordUsesOneShotCaptureTime() {
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
        func slowStageDurationsUseBoundedBuckets() {
            #expect(ErrorReportingService.automaticScreenshotDurationBucket(500) == 500)
            #expect(ErrorReportingService.automaticScreenshotDurationBucket(999) == 500)
            #expect(ErrorReportingService.automaticScreenshotDurationBucket(1000) == 1000)
            #expect(ErrorReportingService.automaticScreenshotDurationBucket(2500) == 2000)
            #expect(ErrorReportingService.automaticScreenshotDurationBucket(8000) == 5000)
        }

        @Test
        func stopBypassesBlockedStartAndInvalidatesPendingSettings() async throws {
            let capture = BlockingAutomaticScreenshotCapture()
            let control = AutomaticScreenshotCaptureControl(capture: capture)
            let request = try makeRequest()
            let startTask = control.enqueue { capture in
                await capture.start(request)
            }
            await capture.waitUntilStartBegins()
            let settingsTask = control.enqueue { capture in
                await capture.updateSettings(intervalSeconds: 10, changeThresholdRatio: 0.30)
            }

            let stopTask = control.stop()
            await capture.waitUntilStopped()
            await capture.resumeStart()
            await startTask.value
            await settingsTask.value
            await stopTask.value
            #expect(await capture.settingsUpdateCount == 0)
        }

        private func makeRequest(
            onPersisted: @escaping @MainActor @Sendable (MeetingScreenshotRecord) -> Void = { _ in },
            onFailure: @escaping @MainActor @Sendable (Error) -> Void = { _ in }
        ) throws -> AutomaticScreenshotCaptureRequest {
            try AutomaticScreenshotCaptureRequest(
                source: .entireDesktop,
                intervalSeconds: 5,
                changeThresholdRatio: 0.20,
                meetingID: .v7(),
                sessionID: .v7(),
                dbQueue: DatabaseQueue(),
                onPersisted: onPersisted,
                onFailure: onFailure
            )
        }
    }

    private enum CaptureFailure: Error {
        case expected
    }

    private actor CaptureProbe {
        private(set) var count = 0

        func fail() throws -> AutomaticScreenshotCaptureOutput {
            count += 1
            throw CaptureFailure.expected
        }
    }

    private actor ControlledSleeper {
        private struct PendingSleep {
            let id: UUID
            let continuation: CheckedContinuation<Void, Error>
        }

        private var durations: [Duration] = []
        private var pendingSleeps: [PendingSleep] = []
        private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        var recordedDurations: [Duration] {
            durations
        }

        func sleep(_ duration: Duration) async throws {
            durations.append(duration)
            resumeSatisfiedWaiters()
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        pendingSleeps.append(PendingSleep(id: id, continuation: continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancel(id: id) }
            }
        }

        func wait(for count: Int) async {
            guard durations.count < count else { return }
            await withCheckedContinuation { continuation in
                countWaiters.append((count, continuation))
            }
        }

        func resumeNext() {
            guard !pendingSleeps.isEmpty else { return }
            pendingSleeps.removeFirst().continuation.resume()
        }

        func resumeAll() {
            let pending = pendingSleeps
            pendingSleeps.removeAll()
            pending.forEach { $0.continuation.resume() }
        }

        private func cancel(id: UUID) {
            guard let index = pendingSleeps.firstIndex(where: { $0.id == id }) else { return }
            pendingSleeps.remove(at: index).continuation.resume(throwing: CancellationError())
        }

        private func resumeSatisfiedWaiters() {
            var pending: [(Int, CheckedContinuation<Void, Never>)] = []
            for waiter in countWaiters {
                if durations.count >= waiter.0 {
                    waiter.1.resume()
                } else {
                    pending.append(waiter)
                }
            }
            countWaiters = pending
        }
    }

    @MainActor
    private final class FailureProbe {
        private var count = 0
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func record(_: Error) {
            count += 1
            var pending: [(Int, CheckedContinuation<Void, Never>)] = []
            for waiter in waiters {
                if count >= waiter.0 {
                    waiter.1.resume()
                } else {
                    pending.append(waiter)
                }
            }
            waiters = pending
        }

        func wait(for expectedCount: Int) async {
            guard count < expectedCount else { return }
            await withCheckedContinuation { continuation in
                waiters.append((expectedCount, continuation))
            }
        }
    }

    @MainActor
    private final class PersistenceProbe {
        private(set) var didPersist = false

        func record() {
            didPersist = true
        }
    }

    private actor BlockingCapture {
        private var continuation: CheckedContinuation<AutomaticScreenshotCaptureOutput, Error>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
        private var attemptWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var didStart = false
        private var wasCancelled = false
        private var attemptCount = 0
        private var activeCount = 0
        private(set) var maximumActiveCount = 0

        func capture() async throws -> AutomaticScreenshotCaptureOutput {
            attemptCount += 1
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
            didStart = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            resumeSatisfiedAttemptWaiters()
            defer { activeCount -= 1 }
            guard attemptCount == 1 else { throw CaptureFailure.expected }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
        }

        func waitUntilStarted() async {
            guard !didStart else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func waitUntilCancelled() async {
            guard !wasCancelled else { return }
            await withCheckedContinuation { continuation in
                cancellationWaiters.append(continuation)
            }
        }

        func wait(for count: Int) async {
            guard attemptCount < count else { return }
            await withCheckedContinuation { continuation in
                attemptWaiters.append((count, continuation))
            }
        }

        func resume(_ output: AutomaticScreenshotCaptureOutput) {
            continuation?.resume(returning: output)
            continuation = nil
        }

        private func recordCancellation() {
            wasCancelled = true
            let waiters = cancellationWaiters
            cancellationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        private func resumeSatisfiedAttemptWaiters() {
            var pending: [(Int, CheckedContinuation<Void, Never>)] = []
            for waiter in attemptWaiters {
                if attemptCount >= waiter.0 {
                    waiter.1.resume()
                } else {
                    pending.append(waiter)
                }
            }
            attemptWaiters = pending
        }
    }

    private enum TestImageError: Error {
        case contextUnavailable
        case imageUnavailable
    }

    private func makeCaptureOutput() throws -> AutomaticScreenshotCaptureOutput {
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.contextUnavailable
        }
        guard let image = context.makeImage() else {
            throw TestImageError.imageUnavailable
        }
        return AutomaticScreenshotCaptureOutput(image: image, capturedAt: .now)
    }

    private actor BlockingAutomaticScreenshotCapture: AutomaticScreenshotCapturing {
        private var startContinuation: CheckedContinuation<Void, Never>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var stopWaiters: [CheckedContinuation<Void, Never>] = []
        private var didBeginStart = false
        private var didStop = false
        private(set) var settingsUpdateCount = 0

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
            settingsUpdateCount += 1
        }

        func stop() {
            didStop = true
            let waiters = stopWaiters
            stopWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        func waitUntilStartBegins() async {
            guard !didBeginStart else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func waitUntilStopped() async {
            guard !didStop else { return }
            await withCheckedContinuation { continuation in
                stopWaiters.append(continuation)
            }
        }

        func resumeStart() {
            startContinuation?.resume()
            startContinuation = nil
        }
    }
#endif
