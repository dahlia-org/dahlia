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

        private func createSegmentedRecording(fixture: BatchAudioTestFixture) async throws {
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
                locale: Locale(identifier: "ja_JP"),
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
            #expect(failed.0.batchLastError == L10n.batchLanguageDetectionFailed)
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
            #expect(completed.1.map(\.text) == ["recognized-2", "recognized-3"])
            #expect(await context.recognizer.localeIdentifiers == ["ja_JP", "ja_JP", "en_US"])
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
    }

    private actor RetryLanguageDetector: BatchLanguageDetecting {
        private enum Step {
            case detection(String)
            case failure
        }

        private var steps: [Step] = [
            .detection("ja"),
            .failure,
            .detection("ja"),
            .detection("en"),
        ]
        private var firstUnloadContinuation: CheckedContinuation<Void, Never>?
        private(set) var firstUnloadHasStarted = false
        private(set) var detectedDuringUnload = false
        private(set) var unloadCount = 0
        private var isUnloading = false

        func detectLanguage(audioURL _: URL) throws -> String {
            if isUnloading {
                detectedDuringUnload = true
                throw BatchLanguageDetectorError.detectionFailed
            }
            guard !steps.isEmpty else { throw BatchLanguageDetectorError.detectionFailed }
            switch steps.removeFirst() {
            case let .detection(languageIdentifier):
                return languageIdentifier
            case .failure:
                throw BatchLanguageDetectorError.detectionFailed
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
#endif
