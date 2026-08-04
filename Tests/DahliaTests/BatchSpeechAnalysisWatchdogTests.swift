@preconcurrency import AVFoundation
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchSpeechAnalysisWatchdogTests {
        @Test
        func noProgressRunsTimeoutAction() async throws {
            let clock = WatchdogTestClock()
            let probe = WatchdogTimeoutProbe()
            let watchdog = BatchSpeechAnalysisWatchdog(timeout: .seconds(60), clock: clock) {
                await probe.recordTimeout()
            }

            await watchdog.start()
            try await waitUntil { await clock.waiterCount == 1 }
            await clock.advance()
            try await waitUntil { await probe.timeoutCount == 1 }

            #expect(await watchdog.didTimeOut)
        }

        @Test
        func progressReplacesTheCurrentDeadline() async throws {
            let clock = WatchdogTestClock()
            let probe = WatchdogTimeoutProbe()
            let watchdog = BatchSpeechAnalysisWatchdog(timeout: .seconds(60), clock: clock) {
                await probe.recordTimeout()
            }

            await watchdog.start()
            try await waitUntil { await clock.waiterCount == 1 }
            let firstSleeperID = try #require(await clock.firstWaiterID)

            await watchdog.recordProgress()
            try await waitUntil {
                let waiterCount = await clock.waiterCount
                let waiterID = await clock.firstWaiterID
                return waiterCount == 1 && waiterID != firstSleeperID
            }
            #expect(await probe.timeoutCount == 0)

            await clock.advance()
            try await waitUntil { await probe.timeoutCount == 1 }
        }

        @Test
        func stopDiscardsTheDeadline() async throws {
            let clock = WatchdogTestClock()
            let probe = WatchdogTimeoutProbe()
            let watchdog = BatchSpeechAnalysisWatchdog(timeout: .seconds(60), clock: clock) {
                await probe.recordTimeout()
            }

            await watchdog.start()
            try await waitUntil { await clock.waiterCount == 1 }
            await watchdog.stop()
            try await waitUntil { await clock.waiterCount == 0 }

            #expect(await probe.timeoutCount == 0)
            #expect(!(await watchdog.didTimeOut))
        }

        @Test
        func timeoutStateRemainsResponsiveWhileTheActionIsSuspended() async throws {
            let clock = WatchdogTestClock()
            let action = SuspendedWatchdogAction()
            let watchdog = BatchSpeechAnalysisWatchdog(timeout: .seconds(60), clock: clock) {
                await action.run()
            }

            await watchdog.start()
            try await waitUntil { await clock.waiterCount == 1 }
            await clock.advance()
            try await waitUntil { await action.runCount == 1 }

            #expect(await watchdog.didTimeOut)
            await watchdog.stop()
            #expect(await action.runCount == 1)
        }

        @Test
        func appleRecognizerStartsWatchdogBeforeAnalyzerPreparation() async throws {
            let clock = WatchdogTestClock()
            let preparation = SuspendedAnalyzerPreparation()
            let audioURL = try makeAudioFile()
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let recognizer = AppleBatchSpeechRecognizer(
                assetPreparer: AppleSpeechAssetPreparer(prepareOperation: { _ in }),
                stallTimeoutProvider: { .oneMinute },
                watchdogClock: clock,
                analyzerPreparation: { _, _ in
                    try await preparation.run()
                }
            )

            let recognitionTask = Task {
                try await recognizer.recognize(audioURL: audioURL, locale: Locale(identifier: "ja_JP"))
            }
            try await waitUntil {
                let didStart = await preparation.didStart
                let waiterCount = await clock.waiterCount
                return didStart && waiterCount == 1
            }

            recognitionTask.cancel()
            _ = try? await recognitionTask.value
        }

        @Test
        func stallTimeoutValuesResolveAndFallBack() {
            #expect(BatchTranscriptionStallTimeout.allCases.map(\.rawValue) == [1, 2, 3])
            #expect(BatchTranscriptionStallTimeout.resolved(rawValue: 1) == .oneMinute)
            #expect(BatchTranscriptionStallTimeout.resolved(rawValue: 2) == .twoMinutes)
            #expect(BatchTranscriptionStallTimeout.resolved(rawValue: 3) == .threeMinutes)
            #expect(BatchTranscriptionStallTimeout.resolved(rawValue: 0) == .oneMinute)
            #expect(BatchTranscriptionStallTimeout.resolved(rawValue: 99) == .oneMinute)
        }

        @Test
        func stallTimeoutStringsAreLocalizedInEnglishAndJapanese() throws {
            let english = try #require(localizationBundle(language: "en"))
            let japanese = try #require(localizationBundle(language: "ja"))

            #expect(localizedDuration(1, bundle: english, locale: Locale(identifier: "en")) == "1 minute")
            #expect(localizedDuration(3, bundle: english, locale: Locale(identifier: "en")) == "3 minutes")
            #expect(localizedDuration(1, bundle: japanese, locale: Locale(identifier: "ja")) == "1分間")
            #expect(localizedDuration(3, bundle: japanese, locale: Locale(identifier: "ja")) == "3分間")
        }

        private func localizationBundle(language: String) -> Bundle? {
            Bundle.appModule.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
        }

        private func localizedDuration(_ minutes: Int, bundle: Bundle, locale: Locale) -> String {
            let key = minutes == 1 ? "%lld minute" : "%lld minutes"
            return String(
                format: bundle.localizedString(forKey: key, value: nil, table: nil),
                locale: locale,
                Int64(minutes)
            )
        }

        private func makeAudioFile() throws -> URL {
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let url = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-watchdog-preparation-\(UUID.v7().uuidString).caf")
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
            buffer.frameLength = 160
            try file.write(from: buffer)
            return url
        }

        private func waitUntil(
            timeout: Duration = testPollTimeout,
            condition: @escaping @Sendable () async -> Bool
        ) async throws {
            let completed = await pollUntil(timeout: timeout, condition)
            #expect(completed)
        }
    }

    private actor WatchdogTimeoutProbe {
        private(set) var timeoutCount = 0

        func recordTimeout() {
            timeoutCount += 1
        }
    }

    private actor SuspendedWatchdogAction {
        private(set) var runCount = 0

        func run() async {
            runCount += 1
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                // The watchdog owns and cancels its outstanding timeout action on stop.
            }
        }
    }

    private actor SuspendedAnalyzerPreparation {
        private(set) var didStart = false

        func run() async throws {
            didStart = true
            try await Task.sleep(for: .seconds(60))
        }
    }

    private actor WatchdogTestClock: BatchSpeechWatchdogClock {
        private struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Void, Error>
        }

        private var waiters: [Waiter] = []

        var waiterCount: Int { waiters.count }
        var firstWaiterID: UUID? { waiters.first?.id }

        func sleep(for _: Duration) async throws {
            let id = UUID.v7()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            } onCancel: {
                Task { await self.cancel(id: id) }
            }
        }

        func advance() {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().continuation.resume()
        }

        private func cancel(id: UUID) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }
#endif
