import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchTranscriptionLocaleConfirmationTests {
        @Test
        func confirmationPreservesLocalesChangedWhileRecording() async throws {
            let batch = try BatchAudioTestFixture(
                name: "recording-locale-ranges",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio()
            try await batch.database.dbQueue.write { db in
                let fetchedRange = try RecordingAudioSegmentRangeRecord.fetchOne(db)
                let firstRange = try #require(fetchedRange)
                var closedFirstRange = firstRange
                closedFirstRange.frameCount = 1
                try closedFirstRange.update(db)
                try RecordingAudioSegmentRangeRecord(
                    id: .v7(),
                    audioSegmentId: firstRange.audioSegmentId,
                    startFrame: 1,
                    frameCount: nil,
                    sessionOffsetSeconds: firstRange.sessionOffsetSeconds,
                    localeIdentifier: "en_US",
                    createdAt: batch.now,
                    updatedAt: batch.now
                ).insert(db)
            }

            let viewModel = CaptionViewModel()
            await viewModel.presentBatchTranscriptionConfirmation(
                sessionId: batch.session.id,
                meetingId: batch.meeting.id,
                dbQueue: batch.database.dbQueue
            )

            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            #expect(confirmation.initialLanguageSelection == .recorded)
        }

        @Test
        func confirmationPreservesLocalesAcrossPendingSessions() async throws {
            let batch = try BatchAudioTestFixture(
                name: "pending-session-locales",
                endedAt: Date(timeIntervalSince1970: 1_776_384_001),
                duration: 1
            )
            defer { batch.removeFiles() }
            try await batch.recordMicrophoneAudio(localeIdentifier: "ja_JP")
            let secondSession = RecordingSessionRecord(
                id: .v7(),
                meetingId: batch.meeting.id,
                startedAt: batch.now.addingTimeInterval(2),
                endedAt: batch.now.addingTimeInterval(3),
                duration: 1,
                offsetSeconds: 2,
                createdAt: batch.now,
                updatedAt: batch.now,
                transcriptionMode: .batch
            )
            let segmentID = UUID.v7()
            try await batch.database.dbQueue.write { db in
                try secondSession.insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO recording_audio_segments (
                        id, recordingSessionId, source, segmentIndex, generationId, state,
                        partialRelativePath, finalRelativePath, sampleRate, channelCount,
                        sessionStartOffsetSeconds, createdAt, updatedAt
                    ) VALUES (?, ?, ?, 0, ?, ?, ?, ?, 16000, 1, 0, ?, ?)
                    """,
                    arguments: [
                        segmentID,
                        secondSession.id,
                        RecordingAudioSource.microphone.rawValue,
                        UUID.v7(),
                        RecordingAudioSegmentState.ready.rawValue,
                        "second.partial.caf",
                        "second.caf",
                        batch.now,
                        batch.now,
                    ]
                )
                try RecordingAudioSegmentRangeRecord(
                    id: .v7(),
                    audioSegmentId: segmentID,
                    startFrame: 0,
                    frameCount: 1,
                    sessionOffsetSeconds: 0,
                    localeIdentifier: "en_US",
                    createdAt: batch.now,
                    updatedAt: batch.now
                ).insert(db)
            }

            let viewModel = CaptionViewModel()
            await viewModel.presentBatchTranscriptionConfirmation(
                sessionId: secondSession.id,
                meetingId: batch.meeting.id,
                dbQueue: batch.database.dbQueue
            )

            let confirmation = try #require(viewModel.pendingBatchTranscriptionConfirmation)
            #expect(confirmation.initialLanguageSelection == .recorded)
        }
    }
#endif
