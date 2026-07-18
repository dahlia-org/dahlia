@preconcurrency import AVFoundation
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchTranscriptionDiscardTests {
        @Test
        func discardingAwaitingSessionPurgesAudioAndKeepsMeeting() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "DiscardAwaiting",
                endedAt: Date(timeIntervalSince1970: 1_776_384_010),
                duration: 10
            )
            defer { fixture.removeFiles() }
            let audio = RecordingAudioSegmentRecord(
                id: .v7(),
                recordingSessionId: fixture.session.id,
                source: .microphone,
                segmentIndex: 0,
                generationId: .v7(),
                state: .ready,
                partialRelativePath: "session/mic/0.partial.caf",
                finalRelativePath: "session/mic/0.caf",
                sampleRate: 16_000,
                channelCount: 1,
                sealedFrameCount: 160,
                sessionStartOffsetSeconds: 0,
                sessionEndOffsetSeconds: 1,
                byteCount: 320,
                sha256: Data(repeating: 1, count: 32),
                finalizationStartedAt: fixture.now,
                integrityVerifiedAt: fixture.now,
                finalizedAt: fixture.now,
                purgeRequestedAt: nil,
                purgedAt: nil,
                failureStage: nil,
                failureCode: nil,
                createdAt: fixture.now,
                updatedAt: fixture.now
            )
            try await fixture.database.dbQueue.write { db in
                try audio.insert(db)
            }

            let discarded = try await MeetingRepository(dbQueue: fixture.database.dbQueue)
                .discardUnprocessedBatchSessionSafely(
                    id: fixture.session.id,
                    managedRootURL: fixture.managedRootURL
                )

            let result = try await fixture.database.dbQueue.read { db in
                try (
                    RecordingSessionRecord.fetchOne(db, key: fixture.session.id),
                    MeetingRecord.fetchOne(db, key: fixture.meeting.id),
                    RecordingAudioSegmentRecord.fetchOne(db, key: audio.id)
                )
            }
            #expect(discarded)
            #expect(result.0?.batchDiscardedAt != nil)
            #expect(result.1?.id == fixture.meeting.id)
            #expect(result.2?.state == .purged)
        }

        @Test
        func discardingFailedSessionPurgesSegmentsAndPreservesTimelineAndExistingTranscript() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "Discard",
                meetingStatus: .ready,
                endedAt: Date(timeIntervalSince1970: 1_776_384_010),
                duration: 10
            )
            defer { fixture.removeFiles() }
            var failedSession = fixture.session
            failedSession.batchLastError = "Audio is damaged"
            let sessionToPersist = failedSession
            let failedSessionId = failedSession.id
            let existingSegment = TranscriptSegmentRecord(
                id: .v7(),
                meetingId: fixture.meeting.id,
                sessionId: nil,
                startTime: fixture.now,
                endTime: fixture.now.addingTimeInterval(1),
                text: "Existing transcript",
                translatedText: nil,
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try await fixture.database.dbQueue.write { db in
                try sessionToPersist.update(db)
                try existingSegment.insert(db)
            }
            let configuration = RecordingAudioStore.Configuration(
                targetSegmentDuration: .seconds(60),
                maximumFinalizingSegmentCountPerSource: 2,
                maximumActiveSegmentDuration: .seconds(600),
                maximumActiveSegmentByteCount: 64 * 1_024 * 1_024,
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
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: recorder.targetFormat, frameCapacity: 320)
            )
            buffer.frameLength = 320
            writer.appendBuffer(buffer)
            try await recorder.finish()

            let store = try RecordingAudioStore(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                configuration: configuration
            )
            let ready = try await fixture.database.dbQueue.read { db in
                try #require(try RecordingAudioSegmentRecord.fetchOne(db))
            }
            let finalURL = fixture.managedRootURL.appending(path: ready.finalRelativePath)
            try await store.fail(segmentId: ready.id, stage: "test", code: "damaged")

            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            let discarded = try await repository.discardFailedBatchSessionSafely(
                id: failedSessionId,
                managedRootURL: fixture.managedRootURL
            )

            let result = try await fixture.database.dbQueue.read { db in
                let session = try RecordingSessionRecord.fetchOne(db, key: failedSessionId)
                let audioSegment = try RecordingAudioSegmentRecord.fetchOne(db, key: ready.id)
                let transcriptSegment = try TranscriptSegmentRecord.fetchOne(db, key: existingSegment.id)
                return try (#require(session), #require(audioSegment), #require(transcriptSegment))
            }
            #expect(discarded)
            #expect(result.0.batchDiscardedAt != nil)
            #expect(result.0.batchLastError == nil)
            #expect(result.0.duration == 10)
            #expect(BatchTranscriptionState.derive(from: result.0) == nil)
            #expect(result.1.state == .purged)
            #expect(result.2.text == "Existing transcript")
            #expect(!FileManager.default.fileExists(atPath: finalURL.path))
        }

        @Test
        func retryQueueClaimAndDiscardClaimCannotBothWin() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "DiscardRetryRace",
                endedAt: Date(timeIntervalSince1970: 1_776_384_010),
                duration: 10
            )
            defer { fixture.removeFiles() }
            var failedSession = fixture.session
            failedSession.batchLastError = "Retryable failure"
            let audio = RecordingAudioSegmentRecord(
                id: .v7(),
                recordingSessionId: fixture.session.id,
                source: .microphone,
                segmentIndex: 0,
                generationId: .v7(),
                state: .ready,
                partialRelativePath: "session/mic/0.partial.caf",
                finalRelativePath: "session/mic/0.caf",
                sampleRate: 16_000,
                channelCount: 1,
                sealedFrameCount: 160,
                sessionStartOffsetSeconds: 0,
                sessionEndOffsetSeconds: 1,
                byteCount: 320,
                sha256: Data(repeating: 1, count: 32),
                finalizationStartedAt: fixture.now,
                integrityVerifiedAt: fixture.now,
                finalizedAt: fixture.now,
                purgeRequestedAt: nil,
                purgedAt: nil,
                failureStage: nil,
                failureCode: nil,
                createdAt: fixture.now,
                updatedAt: fixture.now
            )
            let sessionToPersist = failedSession
            try await fixture.database.dbQueue.write { db in
                try sessionToPersist.update(db)
                try audio.insert(db)
            }
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                onStateChange: { _ in }
            )
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)

            async let enqueue: Void = coordinator.enqueue(sessionId: fixture.session.id)
            async let discard = repository.discardUnprocessedBatchSessionSafely(
                id: fixture.session.id,
                managedRootURL: fixture.managedRootURL
            )
            await enqueue
            let didDiscard = try await discard
            try await Task.sleep(for: .milliseconds(100))

            let result = try await fixture.database.dbQueue.read { db in
                try (
                    #require(try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)),
                    #require(try RecordingAudioSegmentRecord.fetchOne(db, key: audio.id))
                )
            }
            if didDiscard {
                #expect(result.0.batchDiscardedAt != nil)
                #expect(result.0.batchLastError == nil)
                #expect(result.1.state == .purged)
            } else {
                #expect(result.0.batchDiscardedAt == nil)
                #expect(result.1.state != .purged)
            }
        }
    }
#endif
