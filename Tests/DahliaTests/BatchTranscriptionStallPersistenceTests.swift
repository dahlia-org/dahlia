import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchTranscriptionStallPersistenceTests {
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
            #expect(!BatchTranscriptionCoordinator.shouldAutomaticallyRetry(result.0))
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
