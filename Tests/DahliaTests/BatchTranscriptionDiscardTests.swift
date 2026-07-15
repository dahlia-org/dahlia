@preconcurrency import AVFoundation
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchTranscriptionDiscardTests {
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
    }
#endif
