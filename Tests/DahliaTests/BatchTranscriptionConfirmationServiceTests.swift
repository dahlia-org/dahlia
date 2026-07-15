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
                    maximumActiveSegmentByteCount: 64 * 1_024 * 1_024,
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
                localeIdentifier: "en_US",
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
            #expect(result.1.map(\.localeIdentifier) == ["en_US"])
        }
    }
#endif
