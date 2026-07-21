@preconcurrency import AVFoundation
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    struct BatchCoordinatorLanguageTests {
        private struct Context {
            let fixture: BatchAudioTestFixture
            let audioSegments: [RecordingAudioSegmentRecord]
            let detector: RetryLanguageDetector
            let recognizer: CoordinatorSpeechRecognizer
            let coordinator: BatchTranscriptionCoordinator
        }

        @Test
        func failedSecondCAFIsTransactionalAndRetryWaitsForUnload() async throws {
            let context = try await makeContext()
            defer { context.fixture.removeFiles() }

            await context.coordinator.enqueue(sessionId: context.fixture.session.id)
            try await waitUntil { await context.detector.firstUnloadHasStarted }
            try await assertFailedAttempt(context)

            await context.coordinator.enqueue(sessionId: context.fixture.session.id)
            await context.detector.releaseFirstUnload()

            try await waitUntil {
                (try? context.fixture.database.dbQueue.read { db in
                    try RecordingSessionRecord.fetchOne(
                        db,
                        key: context.fixture.session.id
                    )?.batchCompletedAt != nil
                }) == true
            }
            try await waitUntil { await context.detector.unloadCount == 2 }
            try await assertCompletedRetry(context)
        }

        @Test
        func nextLanguageDetectionOverlapsPreviousSpeechRecognition() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "AutomaticLanguagePipeline",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 0.0125,
                retainAudioAfterBatch: true
            )
            defer { fixture.removeFiles() }
            try await createSegmentedRecording(fixture: fixture)
            let probe = BatchPipelineProbe()
            defer { Task { await probe.releaseSecondDetection() } }
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                languageDetector: PipelineLanguageDetector(probe: probe),
                speechRecognizer: PipelineSpeechRecognizer(probe: probe),
                supportedLocalesProvider: {
                    [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")]
                },
                onStateChange: { _ in }
            )

            await coordinator.enqueue(sessionId: fixture.session.id)
            try await waitUntil { await probe.secondDetectionIsActive }
            try await waitUntil { await probe.recognitionCallCount > 0 }
            #expect(await probe.recognitionStartedDuringSecondDetection)
            await probe.releaseSecondDetection()
            try await waitUntil {
                (try? fixture.database.dbQueue.read { db in
                    try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)?.batchCompletedAt != nil
                }) == true
            }

            let transcripts = try await fixture.database.dbQueue.read { db in
                try TranscriptSegmentRecord
                    .filter(Column("sessionId") == fixture.session.id)
                    .order(Column("startTime").asc)
                    .fetchAll(db)
            }
            #expect(transcripts.count == 2)
        }

        @Test
        func unsupportedDetectionFailsBatchInsteadOfFallingBack() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "AutomaticLanguageFallback",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 0.0125,
                retainAudioAfterBatch: true
            )
            defer { fixture.removeFiles() }
            try await createSegmentedRecording(
                fixture: fixture,
                recordedLocale: Locale(identifier: "en_US")
            )
            let detector = SequenceCoordinatorLanguageDetector(detections: ["ja", "jw"])
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                languageDetector: detector,
                speechRecognizer: CoordinatorSpeechRecognizer(),
                supportedLocalesProvider: {
                    [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")]
                },
                onStateChange: { _ in }
            )

            await coordinator.enqueue(sessionId: fixture.session.id)
            try await waitUntil {
                (try? fixture.database.dbQueue.read { db in
                    try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)?.batchLastError != nil
                }) == true
            }

            let transcriptCount = try await fixture.database.dbQueue.read { db in
                try TranscriptSegmentRecord
                    .filter(Column("sessionId") == fixture.session.id)
                    .fetchCount(db)
            }
            #expect(transcriptCount == 0)
            let allowedLanguageIdentifierSets = await detector.allowedLanguageIdentifierSets
            #expect(!allowedLanguageIdentifierSets.isEmpty)
            #expect(allowedLanguageIdentifierSets.allSatisfy { $0 == ["en", "ja"] })
        }

        @Test
        func fallbackDiagnosticsAreReportedWhenSubsequentRecognitionFails() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "AutomaticLanguageFallbackFailure",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 0.0125,
                retainAudioAfterBatch: true
            )
            defer { fixture.removeFiles() }
            try await createSegmentedRecording(
                fixture: fixture,
                recordedLocale: Locale(identifier: "en_US")
            )
            let reportProbe = LanguageFallbackReportProbe()
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                languageDetector: InferenceFailingCoordinatorLanguageDetector(),
                speechRecognizer: FailingCoordinatorSpeechRecognizer(),
                supportedLocalesProvider: {
                    [Locale(identifier: "en_US")]
                },
                languageFallbackReporter: { fallbacks, candidates in
                    await reportProbe.record(
                        fallbacks: fallbacks,
                        candidates: candidates
                    )
                },
                onStateChange: { _ in }
            )

            await coordinator.enqueue(sessionId: fixture.session.id)
            try await waitUntil { await reportProbe.reportCount == 1 }

            #expect(await reportProbe.fallbackCount >= 1)
            let transcriptCount = try await fixture.database.dbQueue.read { db in
                try TranscriptSegmentRecord
                    .filter(Column("sessionId") == fixture.session.id)
                    .fetchCount(db)
            }
            #expect(transcriptCount == 0)
        }

        @Test
        func sentryFallbackReportIncludesInferenceFailureCount() {
            let fallbacks: [BatchLanguageFallback] = [.inferenceFailure]

            let context = BatchTranscriptionCoordinator.languageFallbackReportContext(
                fallbacks,
                candidates: BatchLanguageDetectionCandidateSnapshot(
                    scope: .selected,
                    languageIdentifiers: ["en", "ja"]
                )
            )

            #expect(context["source"] == "batchLanguageDetectionFallback")
            #expect(context["candidateScope"] == "selected")
            #expect(context["candidateLanguageCount"] == "2")
            #expect(context["fallbackCount"] == "1")
            #expect(context["inferenceFailedCount"] == "1")
        }

        @Test
        func sentryFallbackReportPreservesAllLanguageScope() {
            let context = BatchTranscriptionCoordinator.languageFallbackReportContext(
                [.inferenceFailure],
                candidates: BatchLanguageDetectionCandidateSnapshot(
                    scope: .all,
                    languageIdentifiers: ["en", "ja"]
                )
            )

            #expect(context["candidateScope"] == "all")
        }

        private func makeContext() async throws -> Context {
            let fixture = try BatchAudioTestFixture(
                name: "AutomaticLanguageRetry",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 0.0125,
                retainAudioAfterBatch: true
            )
            try await createSegmentedRecording(fixture: fixture)
            let audioSegments = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord.order(Column("segmentIndex").asc).fetchAll(db)
            }
            #expect(audioSegments.count == 2)

            let detector = RetryLanguageDetector()
            let recognizer = CoordinatorSpeechRecognizer()
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                languageDetector: detector,
                speechRecognizer: recognizer,
                supportedLocalesProvider: {
                    [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")]
                },
                onStateChange: { _ in }
            )
            return Context(
                fixture: fixture,
                audioSegments: audioSegments,
                detector: detector,
                recognizer: recognizer,
                coordinator: coordinator
            )
        }

        private func createSegmentedRecording(
            fixture: BatchAudioTestFixture,
            recordedLocale: Locale = Locale(identifier: "ja_JP")
        ) async throws {
            let configuration = RecordingAudioStore.Configuration(
                targetSegmentDuration: .milliseconds(5),
                maximumFinalizingSegmentCountPerSource: 2,
                maximumActiveSegmentDuration: .seconds(600),
                maximumActiveSegmentByteCount: 64 * 1024 * 1024,
                minimumAvailableCapacity: 0,
                capacityCheckInterval: .seconds(5)
            )
            let recorder = try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id,
                recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now,
                sampleRate: 16000,
                configuration: configuration
            )
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: recordedLocale,
                at: fixture.now
            )
            try writer.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 80))
            try writer.appendBuffer(makeBuffer(format: recorder.targetFormat, frameCount: 120))
            try await recorder.finish()

            try await fixture.database.dbQueue.write { db in
                guard var session = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                session.batchLanguageDetectionMode = .automatic
                session.batchSelectedLocaleIdentifier = nil
                session.batchAutomaticLanguageCandidatesJSON = try BatchLanguageDetectionCandidateSnapshot(
                    scope: .selected,
                    languageIdentifiers: ["en", "ja"]
                ).encoded()
                try session.update(db)
            }
        }

        private func assertFailedAttempt(_ context: Context) async throws {
            let failed = try await context.fixture.database.dbQueue.read { db in
                let session = try #require(try RecordingSessionRecord.fetchOne(db, key: context.fixture.session.id))
                let transcriptCount = try TranscriptSegmentRecord
                    .filter(Column("sessionId") == context.fixture.session.id)
                    .fetchCount(db)
                return (session, transcriptCount)
            }
            #expect(failed.0.batchLanguageDetectionMode == .automatic)
            #expect(failed.0.batchLastError == L10n.batchLanguageModelPreparationFailed)
            #expect(failed.0.batchFailureKind == .transcription)
            #expect(failed.0.batchAttemptCount == 1)
            #expect(BatchTranscriptionCoordinator.shouldAutomaticallyRetry(failed.0))
            #expect(failed.1 == 0)
            for segment in context.audioSegments {
                #expect(FileManager.default.fileExists(
                    atPath: context.fixture.managedRootURL.appending(path: segment.finalRelativePath).path
                ))
            }
        }

        private func assertCompletedRetry(_ context: Context) async throws {
            let completed = try await context.fixture.database.dbQueue.read { db in
                let session = try #require(try RecordingSessionRecord.fetchOne(db, key: context.fixture.session.id))
                let transcripts = try TranscriptSegmentRecord
                    .filter(Column("sessionId") == context.fixture.session.id)
                    .order(Column("startTime").asc)
                    .fetchAll(db)
                return (session, transcripts)
            }
            #expect(completed.0.batchCompletedAt != nil)
            #expect(completed.0.batchLastError == nil)
            #expect(completed.0.batchAttemptCount == 2)
            #expect(completed.1.count == 2)
            #expect(completed.1.map(\.speakerLabel) == ["mic", "mic"])
            let localeIdentifiers = await context.recognizer.localeIdentifiers
            #expect((2 ... 3).contains(localeIdentifiers.count))
            #expect(Set(localeIdentifiers.suffix(2)) == ["ja_JP", "en_US"])
            #expect(Set(completed.1.map(\.text)) == [
                "recognized-\(localeIdentifiers.count - 1)",
                "recognized-\(localeIdentifiers.count)",
            ])
            #expect(await !(context.detector.detectedDuringUnload))
        }

        private func makeBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            return buffer
        }

        private func waitUntil(
            timeout: Duration = .seconds(5),
            condition: @escaping @Sendable () async -> Bool
        ) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while await !condition() {
                guard ContinuousClock.now < deadline else {
                    throw CoordinatorLanguageDetectionTestError.timedOut
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private enum CoordinatorLanguageDetectionTestError: Error {
        case timedOut
        case forcedRecognitionFailure
    }

    private actor LanguageFallbackReportProbe {
        private(set) var reportCount = 0
        private(set) var fallbackCount = 0

        func record(
            fallbacks: [BatchLanguageFallback],
            candidates _: BatchLanguageDetectionCandidateSnapshot
        ) {
            reportCount += 1
            fallbackCount += fallbacks.count
        }
    }

    private struct FailingCoordinatorSpeechRecognizer: BatchSpeechRecognizing {
        func recognize(audioURL _: URL, locale _: Locale) throws -> [BatchSpeechRecognition] {
            throw CoordinatorLanguageDetectionTestError.forcedRecognitionFailure
        }
    }

    private actor RetryLanguageDetector: BatchLanguageDetecting {
        private enum Step {
            case detection(String)
            case modelPreparationFailure
        }

        private var steps: [Step] = [
            .detection("ja"),
            .modelPreparationFailure,
            .detection("ja"),
            .detection("en"),
        ]
        private var firstUnloadContinuation: CheckedContinuation<Void, Never>?
        private(set) var firstUnloadHasStarted = false
        private(set) var detectedDuringUnload = false
        private(set) var unloadCount = 0
        private var isUnloading = false

        func detectLanguage(
            audioURL _: URL,
            allowedLanguageIdentifiers _: Set<String>?
        ) throws -> BatchLanguageDetectionOutcome {
            if isUnloading {
                detectedDuringUnload = true
                throw BatchLanguageDetectorError.inferenceFailed
            }
            guard !steps.isEmpty else { throw BatchLanguageDetectorError.inferenceFailed }
            switch steps.removeFirst() {
            case let .detection(languageIdentifier):
                return .confidentDetection(languageIdentifier)
            case .modelPreparationFailure:
                throw BatchLanguageDetectorError.modelPreparationFailed
            }
        }

        func unload() async {
            unloadCount += 1
            isUnloading = true
            if unloadCount == 1 {
                firstUnloadHasStarted = true
                await withCheckedContinuation { continuation in
                    firstUnloadContinuation = continuation
                }
            }
            isUnloading = false
        }

        func releaseFirstUnload() {
            firstUnloadContinuation?.resume()
            firstUnloadContinuation = nil
        }
    }

    private actor CoordinatorSpeechRecognizer: BatchSpeechRecognizing {
        private(set) var localeIdentifiers: [String] = []

        func recognize(audioURL _: URL, locale: Locale) -> [BatchSpeechRecognition] {
            localeIdentifiers.append(locale.identifier)
            return [
                BatchSpeechRecognition(
                    startSeconds: 0.001,
                    endSeconds: 0.002,
                    text: "recognized-\(localeIdentifiers.count)"
                ),
            ]
        }
    }

    private actor SequenceCoordinatorLanguageDetector: BatchLanguageDetecting {
        private var detections: [String]
        private(set) var allowedLanguageIdentifierSets: [Set<String>?] = []

        init(detections: [String]) {
            self.detections = detections
        }

        func detectLanguage(
            audioURL _: URL,
            allowedLanguageIdentifiers: Set<String>?
        ) throws -> BatchLanguageDetectionOutcome {
            allowedLanguageIdentifierSets.append(allowedLanguageIdentifiers)
            guard !detections.isEmpty else { throw BatchLanguageDetectorError.inferenceFailed }
            return .confidentDetection(detections.removeFirst())
        }

        func unload() async {}
    }

    private struct InferenceFailingCoordinatorLanguageDetector: BatchLanguageDetecting {
        func detectLanguage(
            audioURL _: URL,
            allowedLanguageIdentifiers _: Set<String>?
        ) throws -> BatchLanguageDetectionOutcome {
            throw BatchLanguageDetectorError.inferenceFailed
        }

        func unload() async {}
    }

    private actor BatchPipelineProbe {
        private var secondDetectionContinuation: CheckedContinuation<Void, Never>?
        private var recognitionWaiters: [CheckedContinuation<Void, Never>] = []
        private(set) var secondDetectionIsActive = false
        private(set) var recognitionStartedDuringSecondDetection = false
        private(set) var recognitionCallCount = 0

        func holdSecondDetection() async {
            secondDetectionIsActive = true
            let waiters = recognitionWaiters
            recognitionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                secondDetectionContinuation = continuation
            }
            secondDetectionIsActive = false
        }

        func recordRecognitionStart() async {
            recognitionCallCount += 1
            guard recognitionCallCount == 1 else { return }
            if !secondDetectionIsActive {
                await withCheckedContinuation { continuation in
                    recognitionWaiters.append(continuation)
                }
            }
            recognitionStartedDuringSecondDetection = secondDetectionIsActive
        }

        func releaseSecondDetection() {
            secondDetectionContinuation?.resume()
            secondDetectionContinuation = nil
        }
    }

    private actor PipelineLanguageDetector: BatchLanguageDetecting {
        private let probe: BatchPipelineProbe
        private var callCount = 0

        init(probe: BatchPipelineProbe) {
            self.probe = probe
        }

        func detectLanguage(
            audioURL _: URL,
            allowedLanguageIdentifiers _: Set<String>?
        ) async -> BatchLanguageDetectionOutcome {
            callCount += 1
            if callCount == 2 {
                await probe.holdSecondDetection()
                return .confidentDetection("en")
            }
            return .confidentDetection("ja")
        }

        func unload() async {}
    }

    private actor PipelineSpeechRecognizer: BatchSpeechRecognizing {
        private let probe: BatchPipelineProbe

        init(probe: BatchPipelineProbe) {
            self.probe = probe
        }

        func recognize(audioURL _: URL, locale: Locale) async -> [BatchSpeechRecognition] {
            await probe.recordRecognitionStart()
            return [
                BatchSpeechRecognition(
                    startSeconds: 0.001,
                    endSeconds: 0.002,
                    text: locale.identifier
                ),
            ]
        }
    }
#endif
