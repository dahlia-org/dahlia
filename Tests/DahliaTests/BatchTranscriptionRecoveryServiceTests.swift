import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchTranscriptionRecoveryServiceTests {
        @Test
        func recoversPartialCAFAndOpenRangeAfterCrash() async throws {
            let fixture = try BatchAudioTestFixture(name: "Recovery")
            defer { fixture.removeFiles() }
            let audioRecord = fixture.makeAudioRecord(finalizedAt: nil, totalFrameCount: nil)
            let range = RecordingAudioRangeRecord(
                id: .v7(),
                audioFileId: audioRecord.id,
                startFrame: 0,
                frameCount: nil,
                sessionOffsetSeconds: 0,
                localeIdentifier: "ja_JP",
                createdAt: fixture.now,
                updatedAt: fixture.now
            )
            try await fixture.database.dbQueue.write { db in
                try audioRecord.insert(db)
                try range.insert(db)
            }

            let partialURL = BatchAudioStorage.partialURL(
                baseURL: fixture.managedRootURL,
                relativePath: fixture.managedRelativePath
            )
            try BatchAudioTestFixture.writeCAF(url: partialURL, frameCount: 320)
            try BatchTranscriptionRecoveryService.recoverAudioMetadataIfNeeded(
                sessionId: fixture.session.id,
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL
            )

            let result = try await fixture.database.dbQueue.read { db in
                let recoveredSession = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
                let recoveredMeeting = try MeetingRecord.fetchOne(db, key: fixture.meeting.id)
                let recoveredFile = try RecordingAudioFileRecord.fetchOne(db, key: audioRecord.id)
                let recoveredRange = try RecordingAudioRangeRecord.fetchOne(db, key: range.id)
                return try (
                    #require(recoveredSession),
                    #require(recoveredMeeting),
                    #require(recoveredFile),
                    #require(recoveredRange)
                )
            }
            #expect(result.0.endedAt == fixture.now.addingTimeInterval(0.02))
            #expect(result.0.duration == 0.02)
            #expect(result.1.duration == 0.02)
            #expect(result.2.totalFrameCount == 320)
            #expect(result.3.frameCount == 320)
            #expect(!FileManager.default.fileExists(atPath: partialURL.path))
            let finalURL = BatchAudioStorage.finalURL(
                baseURL: fixture.managedRootURL,
                relativePath: fixture.managedRelativePath
            )
            #expect(FileManager.default.fileExists(atPath: finalURL.path))
        }

        @Test
        func coordinatorRecoversInterruptedRecordingIntoConfirmationState() async throws {
            let fixture = try BatchAudioTestFixture(name: "CoordinatorRecovery")
            defer { fixture.removeFiles() }
            let audioRecord = fixture.makeAudioRecord(finalizedAt: nil, totalFrameCount: nil)
            let range = RecordingAudioRangeRecord(
                id: .v7(),
                audioFileId: audioRecord.id,
                startFrame: 0,
                frameCount: nil,
                sessionOffsetSeconds: 0,
                localeIdentifier: "ja_JP",
                createdAt: fixture.now,
                updatedAt: fixture.now
            )
            try await fixture.database.dbQueue.write { db in
                try audioRecord.insert(db)
                try range.insert(db)
            }
            let partialURL = BatchAudioStorage.partialURL(
                baseURL: fixture.managedRootURL,
                relativePath: fixture.managedRelativePath
            )
            try BatchAudioTestFixture.writeCAF(url: partialURL, frameCount: 320)
            let coordinator = BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                onStateChange: { _ in }
            )

            await coordinator.recoverAndEnqueue()

            let session = try await fixture.database.dbQueue.read { db in
                let record = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
                return try #require(record)
            }
            #expect(session.endedAt != nil)
            #expect(session.batchLastAttemptAt == nil)
            #expect(BatchTranscriptionState.derive(from: session) == .awaitingConfirmation(sessionId: session.id))
        }
    }
#endif
