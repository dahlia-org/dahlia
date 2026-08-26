import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchRetranscriptionRecoveryTests {
        @Test
        func cancelledRetranscriptionRejectsAStaleCompletion() async throws {
            let completedAt = Date(timeIntervalSince1970: 1_776_384_060)
            let fixture = try BatchAudioTestFixture(
                name: "CancelRetranscriptionStaleCompletion",
                endedAt: completedAt.addingTimeInterval(-30),
                duration: 30,
                batchCompletedAt: completedAt
            )
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let previousTranscript = makeTranscriptRecord(fixture: fixture, text: "previous transcript")
            try await fixture.database.dbQueue.write { db in
                try previousTranscript.insert(db)
            }
            _ = try await BatchTranscriptionConfirmationService.confirmRetranscription(
                sessionIds: [fixture.session.id],
                languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil,
                dbQueue: fixture.database.dbQueue
            )
            _ = try await BatchTranscriptionConfirmationService.cancelRetranscription(
                sessionIds: [fixture.session.id],
                dbQueue: fixture.database.dbQueue
            )

            #expect(throws: CancellationError.self) {
                try BatchTranscriptionPersistence.complete(
                    sessionId: fixture.session.id,
                    meetingId: fixture.meeting.id,
                    records: [makeTranscriptRecord(fixture: fixture, text: "stale replacement")],
                    completedAt: completedAt.addingTimeInterval(10),
                    dbQueue: fixture.database.dbQueue
                )
            }
            let transcripts = try await fixture.database.dbQueue.read { db in
                try TranscriptSegmentRecord
                    .filter(Column("sessionId") == fixture.session.id)
                    .fetchAll(db)
            }
            #expect(transcripts.map(\.text) == ["previous transcript"])
        }

        @Test
        func startupRecoveryKeepsAudioForAStalledRetranscription() async throws {
            let completedAt = Date(timeIntervalSince1970: 1_776_384_060)
            let fixture = try BatchAudioTestFixture(
                name: "StalledRetranscriptionAudioRecovery",
                endedAt: completedAt.addingTimeInterval(-30),
                duration: 30,
                batchCompletedAt: completedAt
            )
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            _ = try await BatchTranscriptionConfirmationService.confirmRetranscription(
                sessionIds: [fixture.session.id],
                languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil,
                dbQueue: fixture.database.dbQueue
            )
            try await fixture.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE recording_sessions SET batchLastError = ?, batchFailureKind = ? WHERE id = ?",
                    arguments: [
                        L10n.batchAnalysisStalled(minutes: 1),
                        BatchFailureKind.transcriptionStalled.rawValue,
                        fixture.session.id,
                    ]
                )
            }

            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                speechRecognizer: TestBatchSpeechRecognizer(),
                supportedLocalesProvider: { testSupportedSpeechLocales },
                onStateChange: { _ in }
            )
            try await coordinator.recoverAndEnqueue()
            let segments = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord
                    .filter(Column("recordingSessionId") == fixture.session.id)
                    .fetchAll(db)
            }

            #expect(segments.map(\.state) == [.ready])
            #expect(segments.allSatisfy { $0.purgedAt == nil })
            #expect(segments.allSatisfy {
                FileManager.default.fileExists(
                    atPath: fixture.managedRootURL.appending(path: $0.finalRelativePath).path
                )
            })
        }

        @Test
        func cancelledRetranscriptionRejectsAStaleFailure() async throws {
            let completedAt = Date(timeIntervalSince1970: 1_776_384_060)
            let fixture = try BatchAudioTestFixture(
                name: "CancelRetranscriptionStaleFailure",
                endedAt: completedAt.addingTimeInterval(-30),
                duration: 30,
                batchCompletedAt: completedAt
            )
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let recognitionGate = DeferredRecognitionFailureGate()
            let updateProbe = BatchUpdateProbe()
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                speechRecognizer: DeferredFailureBatchSpeechRecognizer(gate: recognitionGate),
                supportedLocalesProvider: { testSupportedSpeechLocales },
                onStateChange: { update in
                    await updateProbe.record(update)
                }
            )

            try await coordinator.confirmRetranscriptionAndEnqueue(
                sessionIds: [fixture.session.id],
                languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil,
                onConfirmed: { _ in }
            )
            #expect(await pollUntil { await recognitionGate.didStart })

            _ = try await BatchTranscriptionConfirmationService.cancelRetranscription(
                sessionIds: [fixture.session.id],
                dbQueue: fixture.database.dbQueue
            )
            await recognitionGate.release()
            #expect(await pollUntil {
                await coordinator.runningState(sessionId: fixture.session.id) == nil
            })

            let session = try await fixture.database.dbQueue.read { db in
                try #require(try RecordingSessionRecord.fetchOne(db, key: fixture.session.id))
            }
            #expect(session.batchLastError == nil)
            #expect(BatchTranscriptionState.derive(from: session) == .completed(sessionId: fixture.session.id))
            let hasFailure = await updateProbe.hasFailure
            #expect(!hasFailure)
        }

        private func makeTranscriptRecord(
            fixture: BatchAudioTestFixture,
            text: String
        ) -> TranscriptSegmentRecord {
            TranscriptSegmentRecord(
                id: .v7(),
                meetingId: fixture.meeting.id,
                sessionId: fixture.session.id,
                startTime: fixture.now,
                endTime: fixture.now.addingTimeInterval(1),
                text: text,
                translatedText: nil,
                isConfirmed: true,
                speakerLabel: "mic"
            )
        }
    }

    private enum DeferredRecognitionError: Error {
        case failed
    }

    private actor DeferredRecognitionFailureGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var didStart = false

        func wait() async {
            didStart = true
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private struct DeferredFailureBatchSpeechRecognizer: BatchSpeechRecognizing {
        let gate: DeferredRecognitionFailureGate

        func recognize(audioURL _: URL, locale _: Locale) async throws -> [BatchSpeechRecognition] {
            try await failAfterRelease()
        }

        func recognize(audioSlices _: [BatchSpeechAudioSlice], locale _: Locale) async throws -> [BatchSpeechRecognition] {
            try await failAfterRelease()
        }

        private func failAfterRelease() async throws -> [BatchSpeechRecognition] {
            await gate.wait()
            throw DeferredRecognitionError.failed
        }
    }

    private actor BatchUpdateProbe {
        private var updates: [BatchTranscriptionUpdate] = []

        var hasFailure: Bool {
            updates.contains { update in
                switch update.state {
                case .failed, .retranscriptionFailed:
                    true
                default:
                    false
                }
            }
        }

        func record(_ update: BatchTranscriptionUpdate) {
            updates.append(update)
        }
    }
#endif
