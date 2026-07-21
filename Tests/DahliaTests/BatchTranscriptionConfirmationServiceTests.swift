@preconcurrency import AVFoundation
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchTranscriptionConfirmationServiceTests {
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
            #expect(result.1.map(\.localeIdentifier) == ["en_US"])
        }

        @Test
        func automaticConfirmationPreservesLocaleAndFailedRetryBecomesRecoverableManual() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "AutomaticConfirmation",
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
                retainAudioAfterBatch: true,
                dbQueue: fixture.database.dbQueue
            )

            try await verifyAutomaticConfirmation(fixture)

            try await markBatchFailed(fixture)

            _ = try await BatchTranscriptionConfirmationService.confirm(
                sessionId: fixture.session.id,
                languageSelection: .manual(localeIdentifier: "en_US"),
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
            #expect(!retrySession.retainAudioAfterBatch)
            #expect(retrySession.batchLastError == nil)
            #expect(retrySession.batchFailureKind == nil)
            #expect(retrySession.batchAttemptCount == BatchTranscriptionCoordinator.maximumAutomaticAttemptCount)
            #expect(retrySession.batchLastAttemptAt != nil)
            #expect(BatchTranscriptionCoordinator.shouldAutomaticallyRetry(retrySession))
            #expect(retryResult.1.map(\.localeIdentifier) == ["en_US"])
        }

        private func markBatchFailed(_ fixture: BatchAudioTestFixture) async throws {
            try await fixture.database.dbQueue.write { db in
                guard var session = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                session.batchLastError = L10n.batchLanguageDetectionFailed
                session.batchFailureKind = .transcription
                session.batchLastAttemptAt = fixture.now
                session.batchAttemptCount = BatchTranscriptionCoordinator.maximumAutomaticAttemptCount
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
            #expect(result.1.map(\.localeIdentifier) == ["ja_JP"])
        }
    }
#endif
