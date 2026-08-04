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
                retainAudioAfterBatch: true,
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
                retainAudioAfterBatch: false,
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
                retainAudioAfterBatch: true,
                batchCompletedAt: completedAt
            )
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            _ = try await BatchTranscriptionConfirmationService.confirmRetranscription(
                sessionIds: [fixture.session.id],
                languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil,
                retainAudioAfterBatch: false,
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
                onStateChange: { _ in }
            )
            await coordinator.recoverAndEnqueue()
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
#endif
