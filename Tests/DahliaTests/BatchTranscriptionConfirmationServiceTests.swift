@preconcurrency import AVFoundation
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchTranscriptionConfirmationServiceTests {
        @Test
        func retranscriptionKeepsPreviousTranscriptUntilSuccessfulCompletion() async throws {
            let completedAt = Date(timeIntervalSince1970: 4_000_000_000)
            let fixture = try BatchAudioTestFixture(
                name: "RetranscriptionConfirmation",
                endedAt: Date(timeIntervalSince1970: 1_776_384_030),
                duration: 30,
                retainAudioAfterBatch: true,
                batchCompletedAt: completedAt
            )
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let previousTranscript = TranscriptSegmentRecord(
                id: .v7(),
                meetingId: fixture.meeting.id,
                sessionId: fixture.session.id,
                startTime: fixture.now,
                endTime: fixture.now.addingTimeInterval(1),
                text: "previous transcript",
                translatedText: nil,
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try await fixture.database.dbQueue.write { db in
                try previousTranscript.insert(db)
            }

            let result = try await BatchTranscriptionConfirmationService.confirmRetranscription(
                sessionIds: [fixture.session.id],
                languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil,
                retainAudioAfterBatch: false,
                dbQueue: fixture.database.dbQueue
            )
            let firstAttempt = try await fixture.database.dbQueue.read { db in
                try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
            }
            #expect(firstAttempt?.retainAudioAfterBatch == false)
            #expect(firstAttempt?.isBatchRetranscriptionPending == true)

            _ = try await BatchTranscriptionConfirmationService.confirmRetranscription(
                sessionIds: [fixture.session.id],
                languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil,
                retainAudioAfterBatch: true,
                dbQueue: fixture.database.dbQueue
            )
            let persisted = try await fixture.database.dbQueue.read { db in
                try (
                    RecordingSessionRecord.fetchOne(db, key: fixture.session.id),
                    TranscriptSegmentRecord.fetchOne(db, key: previousTranscript.id),
                    RecordingAudioSegmentRangeRecord.fetchAll(db)
                )
            }

            #expect(result.meetingId == fixture.meeting.id)
            #expect(result.sessionIds == [fixture.session.id])
            #expect(persisted.0?.batchCompletedAt == completedAt)
            #expect(persisted.0?.isBatchRetranscriptionPending == true)
            #expect(persisted.0?.batchAttemptCount == 0)
            #expect(persisted.1?.text == "previous transcript")
            #expect(persisted.2.map(\.localeIdentifier) == ["en_US"])

            let replacement = TranscriptSegmentRecord(
                id: .v7(),
                meetingId: fixture.meeting.id,
                sessionId: fixture.session.id,
                startTime: fixture.now,
                endTime: fixture.now.addingTimeInterval(1),
                text: "replacement transcript",
                translatedText: nil,
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try BatchTranscriptionPersistence.complete(
                sessionId: fixture.session.id,
                meetingId: fixture.meeting.id,
                records: [replacement],
                completedAt: fixture.now.addingTimeInterval(120),
                dbQueue: fixture.database.dbQueue
            )
            let completedResult = try await fixture.database.dbQueue.read { db in
                try (
                    RecordingSessionRecord.fetchOne(db, key: fixture.session.id),
                    TranscriptSegmentRecord
                        .filter(Column("sessionId") == fixture.session.id)
                        .fetchAll(db)
                )
            }
            #expect(completedResult.0?.isBatchRetranscriptionPending == false)
            #expect(completedResult.0?.batchCompletedAt == persisted.0?.batchLastAttemptAt)
            #expect(completedResult.1.map(\.text) == ["replacement transcript"])
        }

        @Test
        func retranscriptionRejectsIncompleteRetainedAudio() async throws {
            let completedAt = Date(timeIntervalSince1970: 1_776_384_060)
            let fixture = try BatchAudioTestFixture(
                name: "RetranscriptionIncompleteAudio",
                endedAt: completedAt.addingTimeInterval(-30),
                duration: 30,
                retainAudioAfterBatch: true,
                batchCompletedAt: completedAt
            )
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            try await fixture.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE recording_audio_segments SET state = ? WHERE recordingSessionId = ?",
                    arguments: [RecordingAudioSegmentState.failed.rawValue, fixture.session.id]
                )
            }

            await #expect(throws: CocoaError.self) {
                try await BatchTranscriptionConfirmationService.confirmRetranscription(
                    sessionIds: [fixture.session.id],
                    languageSelection: .manual(localeIdentifier: "en_US"),
                    automaticLanguageCandidates: nil,
                    retainAudioAfterBatch: true,
                    dbQueue: fixture.database.dbQueue
                )
            }
        }

        @Test
        func cancellingRetranscriptionRestoresRetainedCompletedState() async throws {
            let completedAt = Date(timeIntervalSince1970: 1_776_384_060)
            let fixture = try BatchAudioTestFixture(
                name: "CancelRetranscription",
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
                    sql: "UPDATE recording_sessions SET batchLastError = ? WHERE id = ?",
                    arguments: ["failed", fixture.session.id]
                )
            }

            let meetingId = try await BatchTranscriptionConfirmationService.cancelRetranscription(
                sessionIds: [fixture.session.id],
                dbQueue: fixture.database.dbQueue
            )
            let session = try await fixture.database.dbQueue.read { db in
                try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
            }

            #expect(meetingId == fixture.meeting.id)
            #expect(session?.isBatchRetranscriptionPending == false)
            #expect(session?.retainAudioAfterBatch == true)
            #expect(session?.audioRetentionPolicy == .keepInApp)
            #expect(session?.batchLastError == nil)
            #expect(session.flatMap { BatchTranscriptionState.derive(from: $0) } == .completed(
                sessionId: fixture.session.id
            ))
        }

        @Test
        func startupRecoveryFinishesDeferredAudioDeletion() async throws {
            let completedAt = Date(timeIntervalSince1970: 1_776_384_060)
            let fixture = try BatchAudioTestFixture(
                name: "DeferredAudioDeletion",
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
            let pending = try await fixture.database.dbQueue.read { db in
                try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
            }
            try BatchTranscriptionPersistence.complete(
                sessionId: fixture.session.id,
                meetingId: fixture.meeting.id,
                records: [],
                completedAt: #require(pending?.batchLastAttemptAt).addingTimeInterval(1),
                dbQueue: fixture.database.dbQueue
            )

            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                onStateChange: { _ in }
            )
            await coordinator.recoverAndEnqueue()
            let segmentStates = try await fixture.database.dbQueue.read { db in
                try RecordingAudioSegmentRecord
                    .filter(Column("recordingSessionId") == fixture.session.id)
                    .fetchAll(db)
                    .map(\.state)
            }

            #expect(segmentStates == [.purged])
        }

        @Test
        func automaticConfirmationRejectsEmptyCandidates() async throws {
            let queue = try DatabaseQueue(path: ":memory:")

            do {
                _ = try await BatchTranscriptionConfirmationService.confirm(
                    sessionId: .v7(),
                    languageSelection: .automatic,
                    automaticLanguageCandidates: BatchLanguageDetectionCandidateSnapshot(
                        scope: .selected,
                        languageIdentifiers: []
                    ),
                    retainAudioAfterBatch: true,
                    dbQueue: queue
                )
                Issue.record("Expected automatic confirmation to reject an empty candidate set")
            } catch let error as BatchSpeechTranscriberError {
                #expect(error.diagnosticCode == "noAutomaticLanguageCandidates")
            }
        }

        @Test(arguments: [
            (retainsAudio: true, policy: RecordingAudioRetentionPolicy.keepInApp),
            (retainsAudio: false, policy: RecordingAudioRetentionPolicy.deleteAfterTranscription),
        ])
        func confirmsSegmentedRangesAndPersistsRetentionPolicy(
            retainsAudio: Bool,
            policy: RecordingAudioRetentionPolicy
        ) async throws {
            let fixture = try BatchAudioTestFixture(
                name: "SegmentedConfirmation-\(retainsAudio)",
                endedAt: Date(timeIntervalSince1970: 1_776_384_060),
                duration: 60
            )
            defer { fixture.removeFiles() }
            let recorder = try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id,
                recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now,
                sampleRate: 16000,
                configuration: RecordingAudioStore.Configuration(
                    targetSegmentDuration: .seconds(60),
                    maximumFinalizingSegmentCountPerSource: 2,
                    maximumActiveSegmentDuration: .seconds(600),
                    maximumActiveSegmentByteCount: 64 * 1024 * 1024,
                    minimumAvailableCapacity: 0,
                    capacityCheckInterval: .seconds(5)
                )
            )
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: recorder.targetFormat,
                frameCapacity: 160
            ))
            buffer.frameLength = 160
            writer.appendBuffer(buffer)
            try await recorder.finish()

            let confirmation = try await BatchTranscriptionConfirmationService.confirm(
                sessionId: fixture.session.id,
                languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil,
                retainAudioAfterBatch: retainsAudio,
                dbQueue: fixture.database.dbQueue
            )
            let result = try await fixture.database.dbQueue.read { db in
                try (
                    RecordingSessionRecord.fetchOne(db, key: fixture.session.id),
                    RecordingAudioSegmentRangeRecord.fetchAll(db)
                )
            }
            #expect(confirmation.sessionIds == [fixture.session.id])
            #expect(result.0?.retainAudioAfterBatch == retainsAudio)
            #expect(result.0?.audioRetentionPolicy == policy)
            #expect(result.0?.batchLastAttemptAt != nil)
            #expect(result.0?.batchLanguageDetectionMode == .manual)
            #expect(result.0?.batchSelectedLocaleIdentifier == "en_US")
            #expect(result.0?.batchAutomaticLanguageCandidatesJSON == nil)
            #expect(result.1.map(\.localeIdentifier) == ["en_US"])
        }

        @Test(arguments: [
            0,
            BatchTranscriptionCoordinator.maximumAutomaticAttemptCount,
        ])
        func automaticConfirmationPreservesLocaleAndFailedRetryBecomesRecoverableManual(
            failedAttemptCount: Int
        ) async throws {
            let fixture = try BatchAudioTestFixture(
                name: "AutomaticConfirmation-(failedAttemptCount)",
                endedAt: Date(timeIntervalSince1970: 1_776_384_030),
                duration: 30
            )
            defer { fixture.removeFiles() }
            let recorder = try BatchAudioRecordingSession(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                meetingId: fixture.meeting.id,
                recordingSessionId: fixture.session.id,
                recordingStartTime: fixture.now,
                sampleRate: 16000,
                configuration: RecordingAudioStore.Configuration(
                    targetSegmentDuration: .seconds(30),
                    maximumFinalizingSegmentCountPerSource: 2,
                    maximumActiveSegmentDuration: .seconds(600),
                    maximumActiveSegmentByteCount: 64 * 1024 * 1024,
                    minimumAvailableCapacity: 0,
                    capacityCheckInterval: .seconds(5)
                )
            )
            let writer = try await recorder.beginRange(
                source: .microphone,
                locale: Locale(identifier: "ja_JP"),
                at: fixture.now
            )
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: recorder.targetFormat, frameCapacity: 160))
            buffer.frameLength = 160
            writer.appendBuffer(buffer)
            try await recorder.finish()

            _ = try await BatchTranscriptionConfirmationService.confirm(
                sessionId: fixture.session.id,
                languageSelection: .automatic,
                automaticLanguageCandidates: BatchLanguageDetectionCandidateSnapshot(
                    scope: .selected,
                    languageIdentifiers: ["en", "ja"]
                ),
                retainAudioAfterBatch: true,
                dbQueue: fixture.database.dbQueue
            )

            try await verifyAutomaticConfirmation(fixture)

            try await markBatchFailed(fixture, attemptCount: failedAttemptCount)

            _ = try await BatchTranscriptionConfirmationService.confirm(
                sessionId: fixture.session.id,
                languageSelection: .manual(localeIdentifier: "en_US"),
                automaticLanguageCandidates: nil,
                retainAudioAfterBatch: false,
                dbQueue: fixture.database.dbQueue
            )

            let retryResult = try await fixture.database.dbQueue.read { db in
                try (
                    RecordingSessionRecord.fetchOne(db, key: fixture.session.id),
                    RecordingAudioSegmentRangeRecord.fetchAll(db)
                )
            }
            let retrySession = try #require(retryResult.0)
            #expect(retrySession.batchLanguageDetectionMode == .manual)
            #expect(retrySession.batchSelectedLocaleIdentifier == "en_US")
            #expect(retrySession.batchAutomaticLanguageCandidatesJSON == nil)
            #expect(!retrySession.retainAudioAfterBatch)
            #expect(retrySession.batchLastError == nil)
            #expect(retrySession.batchFailureKind == nil)
            #expect(retrySession.batchAttemptCount == failedAttemptCount)
            #expect(retrySession.batchLastAttemptAt != nil)
            #expect(BatchTranscriptionCoordinator.shouldAutomaticallyRetry(retrySession))
            #expect(retryResult.1.map(\.localeIdentifier) == ["en_US"])
        }

        private func markBatchFailed(
            _ fixture: BatchAudioTestFixture,
            attemptCount: Int
        ) async throws {
            try await fixture.database.dbQueue.write { db in
                guard var session = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                session.batchLastError = L10n.batchLanguageDetectionFailed
                session.batchFailureKind = attemptCount == 0 ? .recordingStorage : .transcription
                session.batchLastAttemptAt = fixture.now
                session.batchAttemptCount = attemptCount
                try session.update(db)
            }
        }

        private func verifyAutomaticConfirmation(_ fixture: BatchAudioTestFixture) async throws {
            let result = try await fixture.database.dbQueue.read { db in
                try (
                    RecordingSessionRecord.fetchOne(db, key: fixture.session.id),
                    RecordingAudioSegmentRangeRecord.fetchAll(db)
                )
            }
            #expect(result.0?.batchLanguageDetectionMode == .automatic)
            #expect(result.0?.batchSelectedLocaleIdentifier == nil)
            let candidatesJSON = try #require(result.0?.batchAutomaticLanguageCandidatesJSON)
            let candidates = try BatchLanguageDetectionCandidateSnapshot.decode(candidatesJSON)
            #expect(candidates.scope == .selected)
            #expect(candidates.identifierSet == ["en", "ja"])
            #expect(result.1.map(\.localeIdentifier) == ["ja_JP"])
        }

    }
#endif
