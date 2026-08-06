import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchTranscriptionStallPersistenceTests {
        @Test
        func startupMarksConfirmedWorkInterruptedWithoutStartingSpeech() async throws {
            let batch = try BatchAudioTestFixture(
                name: "startup-manual-resume",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            _ = try await BatchTranscriptionConfirmationService.confirm(
                sessionId: batch.session.id,
                languageSelection: .manual(localeIdentifier: "ja_JP"),
                automaticLanguageCandidates: nil,
                retainAudioAfterBatch: true,
                dbQueue: batch.database.dbQueue
            )
            let retryProbe = BatchRecognitionCallProbe()
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: batch.database.dbQueue,
                managedRootURL: batch.managedRootURL,
                speechRecognizer: CountingBatchSpeechRecognizer(probe: retryProbe),
                onStateChange: { _ in }
            )

            await coordinator.recoverAndEnqueue()

            let session = try await batch.database.dbQueue.read { db in
                try #require(try RecordingSessionRecord.fetchOne(db, key: batch.session.id))
            }
            #expect(await retryProbe.callCount == 0)
            #expect(session.batchFailureKind == .transcriptionInterrupted)
            #expect(BatchTranscriptionState.derive(from: session) == .interrupted(
                sessionId: batch.session.id,
                isRetranscription: false
            ))
        }

        @Test
        func shutdownCancelsRecognitionAndPersistsManualResumeState() async throws {
            let batch = try BatchAudioTestFixture(
                name: "shutdown-manual-resume",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            try await batch.database.dbQueue.write { db in
                guard var session = try RecordingSessionRecord.fetchOne(db, key: batch.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                session.batchSelectedLocaleIdentifier = "ja_JP"
                try session.update(db)
            }
            let recognizer = ShutdownSpeechRecognizer()
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: batch.database.dbQueue,
                managedRootURL: batch.managedRootURL,
                speechRecognizer: recognizer,
                onStateChange: { _ in }
            )
            await coordinator.enqueue(sessionId: batch.session.id)
            #expect(await pollUntil { await recognizer.didStart })

            await coordinator.shutdown()

            let session = try await batch.database.dbQueue.read { db in
                try #require(try RecordingSessionRecord.fetchOne(db, key: batch.session.id))
            }
            #expect(session.batchFailureKind == .transcriptionInterrupted)
            #expect(BatchTranscriptionState.derive(from: session) == .interrupted(
                sessionId: batch.session.id,
                isRetranscription: false
            ))
        }

        @Test
        func confirmationFinishingAfterShutdownDoesNotStartSpeech() async throws {
            let batch = try BatchAudioTestFixture(
                name: "shutdown-during-confirmation",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            let recognitionProbe = BatchRecognitionCallProbe()
            let confirmationGate = BatchConfirmationGate()
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: batch.database.dbQueue,
                managedRootURL: batch.managedRootURL,
                speechRecognizer: CountingBatchSpeechRecognizer(probe: recognitionProbe),
                onStateChange: { _ in }
            )
            let confirmationTask = Task {
                try await coordinator.confirmAndEnqueue(
                    sessionId: batch.session.id,
                    languageSelection: .manual(localeIdentifier: "ja_JP"),
                    automaticLanguageCandidates: nil,
                    retainAudioAfterBatch: true,
                    onConfirmed: { _ in await confirmationGate.wait() }
                )
            }
            #expect(await pollUntil { await confirmationGate.isWaiting })

            await coordinator.shutdown()
            await confirmationGate.release()
            try await confirmationTask.value

            let session = try await batch.database.dbQueue.read { db in
                try #require(try RecordingSessionRecord.fetchOne(db, key: batch.session.id))
            }
            #expect(await recognitionProbe.callCount == 0)
            #expect(session.batchFailureKind == .transcriptionInterrupted)
            #expect(BatchTranscriptionState.derive(from: session) == .interrupted(
                sessionId: batch.session.id,
                isRetranscription: false
            ))
        }

        @Test
        func stalledRecognitionPersistsManualFailureAndKeepsReadyAudio() async throws {
            let batch = try BatchAudioTestFixture(
                name: "stalled-recognition",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1,
                retainAudioAfterBatch: false
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            try await batch.database.dbQueue.write { db in
                guard var session = try RecordingSessionRecord.fetchOne(db, key: batch.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                session.batchSelectedLocaleIdentifier = "ja_JP"
                try session.update(db)
            }
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: batch.database.dbQueue,
                managedRootURL: batch.managedRootURL,
                speechRecognizer: StalledBatchSpeechRecognizer(),
                onStateChange: { _ in }
            )

            await coordinator.enqueue(sessionId: batch.session.id)
            #expect(await pollUntil {
                (try? batch.database.dbQueue.read { db in
                    try RecordingSessionRecord.fetchOne(db, key: batch.session.id)?.batchFailureKind == .transcriptionStalled
                }) == true
            })

            let result = try await batch.database.dbQueue.read { db in
                let session = try #require(try RecordingSessionRecord.fetchOne(db, key: batch.session.id))
                let segment = try #require(try RecordingAudioSegmentRecord.fetchOne(db))
                return (session, segment)
            }
            #expect(result.0.batchLastError == L10n.batchAnalysisStalled(minutes: 1))
            #expect(result.0.batchFailureKind == .transcriptionStalled)
            #expect(result.1.state == .ready)
            #expect(result.1.purgedAt == nil)
            #expect(FileManager.default.fileExists(
                atPath: batch.managedRootURL.appending(path: result.1.finalRelativePath).path
            ))

            let retryProbe = BatchRecognitionCallProbe()
            let recoveryCoordinator = BatchTranscriptionCoordinator(
                dbQueue: batch.database.dbQueue,
                managedRootURL: batch.managedRootURL,
                speechRecognizer: CountingBatchSpeechRecognizer(probe: retryProbe),
                onStateChange: { _ in }
            )
            await recoveryCoordinator.recoverAndEnqueue()
            #expect(await retryProbe.callCount == 0)
        }
    }

    private struct StalledBatchSpeechRecognizer: BatchSpeechRecognizing {
        func recognize(audioURL _: URL, locale _: Locale) throws -> [BatchSpeechRecognition] {
            throw BatchSpeechTranscriberError.analysisStalled(minutes: 1)
        }

        func recognize(audioSlices _: [BatchSpeechAudioSlice], locale _: Locale) throws -> [BatchSpeechRecognition] {
            throw BatchSpeechTranscriberError.analysisStalled(minutes: 1)
        }
    }

    private actor BatchRecognitionCallProbe {
        private(set) var callCount = 0

        func recordCall() {
            callCount += 1
        }
    }

    private actor BatchConfirmationGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func wait() async {
            isWaiting = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
            isWaiting = false
        }
    }

    private actor ShutdownSpeechRecognizer: BatchSpeechRecognizing {
        private var continuation: CheckedContinuation<[BatchSpeechRecognition], Error>?
        private(set) var didStart = false

        func recognize(audioURL _: URL, locale _: Locale) async throws -> [BatchSpeechRecognition] {
            try await suspendUntilCancelled()
        }

        func recognize(audioSlices _: [BatchSpeechAudioSlice], locale _: Locale) async throws -> [BatchSpeechRecognition] {
            try await suspendUntilCancelled()
        }

        private func suspendUntilCancelled() async throws -> [BatchSpeechRecognition] {
            didStart = true
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        self.continuation = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancel() }
            }
        }

        private func cancel() {
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }
    }

    private struct CountingBatchSpeechRecognizer: BatchSpeechRecognizing {
        let probe: BatchRecognitionCallProbe

        func recognize(audioURL _: URL, locale _: Locale) async -> [BatchSpeechRecognition] {
            await probe.recordCall()
            return []
        }

        func recognize(audioSlices _: [BatchSpeechAudioSlice], locale _: Locale) async -> [BatchSpeechRecognition] {
            await probe.recordCall()
            return []
        }
    }
#endif
