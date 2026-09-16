import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchRetranscriptionRecoveryTests {
        @Test
        func partialRetranscriptionIgnoresExpiredSiblingAndPreservesItsTranscript() async throws {
            let completedAt = Date(timeIntervalSince1970: 1_776_384_060)
            let fixture = try BatchAudioTestFixture(
                name: "RetranscriptionExpiredSibling",
                endedAt: completedAt.addingTimeInterval(-30),
                duration: 30,
                batchCompletedAt: completedAt
            )
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let expiredSession = RecordingSessionRecord(
                id: .v7(),
                meetingId: fixture.meeting.id,
                startedAt: fixture.now.addingTimeInterval(30),
                endedAt: fixture.now.addingTimeInterval(60),
                duration: 30,
                offsetSeconds: 30,
                createdAt: fixture.now,
                updatedAt: fixture.now,
                transcriptionMode: .batch,
                batchCompletedAt: completedAt
            )
            let previousTranscript = makeTranscriptRecord(fixture: fixture, text: "selected previous transcript")
            let expiredTranscript = TranscriptContent(
                id: .v7(),
                meetingId: fixture.meeting.id,
                sessionId: expiredSession.id,
                startTime: expiredSession.startedAt,
                endTime: expiredSession.startedAt.addingTimeInterval(30),
                text: "expired sibling transcript",
                translatedText: nil,
                isConfirmed: true,
                audioSource: "mic"
            )
            let selectedSourceRecordingNumber = 2
            let expiredSourceRecordingNumber = 1
            let selectedDestinationRecordingNumber = 1
            let selectedInput = TranscriptMetadata.Run.AudioInput(
                recordingNumber: selectedSourceRecordingNumber,
                source: "mic",
                checksum: "SHA-256:" + String(repeating: "1", count: 64)
            )
            let expiredInput = TranscriptMetadata.Run.AudioInput(
                recordingNumber: expiredSourceRecordingNumber,
                source: "mic",
                checksum: "SHA-256:" + String(repeating: "2", count: 64)
            )
            let selectedArchiveAudio = RecordingArchivedAudio(
                contentType: "audio/mp4",
                size: 1,
                checksum: selectedInput.checksum,
                contentURL: "/recording",
                manifest: .init(sampleRate: 16000, frameCount: 1, ranges: [])
            )
            let selectedArchiveAudioJSON = try String(
                decoding: SyncJSON.encoder.encode(["mic": selectedArchiveAudio]),
                as: UTF8.self
            )
            let previousServerRun = {
                var run = TranscriptMetadata.Run(
                    generatedBy: "server",
                    startedAt: fixture.now,
                    completedAt: completedAt
                )
                run.audioInputs = [selectedInput, expiredInput]
                return run
            }()
            try await fixture.database.dbQueue.write { db in
                try expiredSession.insert(db)
                try RecordingArchiveRecord(
                    sessionId: fixture.session.id,
                    meetingId: fixture.meeting.id,
                    workspaceId: fixture.meeting.workspaceId,
                    number: selectedDestinationRecordingNumber,
                    audioJSON: selectedArchiveAudioJSON
                ).insert(db)
                try RecordingArchiveRecord(
                    sessionId: expiredSession.id,
                    meetingId: fixture.meeting.id,
                    workspaceId: fixture.meeting.workspaceId,
                    number: expiredSourceRecordingNumber,
                    state: "expired"
                ).insert(db)
                try previousTranscript.insert(db)
                try expiredTranscript.insert(db)
                try db.execute(
                    sql: "UPDATE transcript_segments SET sessionId = NULL WHERE meetingId = ?",
                    arguments: [fixture.meeting.id]
                )
                try TranscriptRecord(
                    meetingId: fixture.meeting.id,
                    info: TranscriptInfo(
                        id: .v7(),
                        startedAt: fixture.now,
                        endedAt: completedAt,
                        metadata: .init(
                            provider: "gemini",
                            model: "gemini",
                            runs: [previousServerRun]
                        )
                    )
                ).insert(db)
            }
            let confirmationProbe = BatchConfirmationProbe()
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                speechRecognizer: ReplacementBatchSpeechRecognizer(),
                supportedLocalesProvider: { testSupportedSpeechLocales },
                onStateChange: { _ in }
            )

            try await coordinator.confirmRetranscriptionAndEnqueue(
                sessionIds: [fixture.session.id],
                languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil,
                onConfirmed: { await confirmationProbe.record($0) }
            )
            #expect(await pollUntil {
                await coordinator.runningState(sessionId: fixture.session.id) == nil
            })

            let persisted = try await fixture.database.dbQueue.read { db in
                try (
                    RecordingSessionRecord.fetchOne(db, key: fixture.session.id),
                    RecordingSessionRecord.fetchOne(db, key: expiredSession.id),
                    TextContentAccess.transcript(meetingId: fixture.meeting.id, in: db),
                    TranscriptRecord.current(fixture.meeting.id, in: db)
                )
            }
            #expect(await confirmationProbe.sessionIds == [fixture.session.id])
            #expect(persisted.0?.isBatchRetranscriptionPending == false)
            #expect(try #require(persisted.0?.batchCompletedAt) > completedAt)
            #expect(persisted.1?.batchCompletedAt == completedAt)
            #expect(persisted.2.map(\.text) == ["replacement transcript", "expired sibling transcript"])
            #expect(persisted.2.map(\.sessionId) == [fixture.session.id, nil])
            let persistedRuns = try #require(persisted.3?.metadata?.runs)
            #expect(persistedRuns.count == 2)
            #expect(persistedRuns.first?.recordingSessionId == nil)
            #expect(persistedRuns.first?.audioInputs == [expiredInput])
            #expect(!persistedRuns.flatMap { $0.audioInputs ?? [] }.contains(selectedInput))
            #expect(persistedRuns.last?.recordingSessionId == fixture.session.id)
        }

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
                try fetchSessionTranscriptContent(sessionId: fixture.session.id, in: db)
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
        ) -> TranscriptContent {
            TranscriptContent(
                id: .v7(),
                meetingId: fixture.meeting.id,
                sessionId: fixture.session.id,
                startTime: fixture.now,
                endTime: fixture.now.addingTimeInterval(1),
                text: text,
                translatedText: nil,
                isConfirmed: true,
                audioSource: "mic"
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

    private struct ReplacementBatchSpeechRecognizer: BatchSpeechRecognizing {
        func recognize(audioURL _: URL, locale _: Locale) -> [BatchSpeechRecognition] {
            replacement
        }

        func recognize(audioSlices _: [BatchSpeechAudioSlice], locale _: Locale) -> [BatchSpeechRecognition] {
            replacement
        }

        private var replacement: [BatchSpeechRecognition] {
            [BatchSpeechRecognition(startSeconds: 0, endSeconds: 0.005, text: "replacement transcript")]
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

    private actor BatchConfirmationProbe {
        private(set) var sessionIds: [UUID] = []

        func record(_ result: BatchTranscriptionConfirmationService.Result) {
            sessionIds = result.sessionIds
        }
    }
#endif
