@preconcurrency import AVFoundation
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchAudioTestFixture {
        let database: AppDatabaseManager
        let testRootURL: URL
        let managedRootURL: URL
        let vaultURL: URL
        let now: Date
        let meeting: MeetingRecord
        let session: RecordingSessionRecord

        init(
            name: String,
            meetingStatus: MeetingStatus = .transcriptNotFound,
            endedAt: Date? = nil,
            duration: TimeInterval? = nil,
            retainAudioAfterBatch: Bool = false,
            batchCompletedAt: Date? = nil
        ) throws {
            database = try AppDatabaseManager(path: ":memory:")
            testRootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-\(name)-test-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
            managedRootURL = testRootURL.appending(path: "Managed", directoryHint: .isDirectory)
            vaultURL = testRootURL.appending(path: "Vault", directoryHint: .isDirectory)
            now = Date(timeIntervalSince1970: 1_776_384_000)

            let vault = VaultRecord(id: .v7(), path: vaultURL.path, name: "Test", createdAt: now, lastOpenedAt: now)
            meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: name,
                status: meetingStatus,
                duration: duration,
                createdAt: now,
                updatedAt: now
            )
            session = RecordingSessionRecord(
                id: .v7(),
                meetingId: meeting.id,
                startedAt: now,
                endedAt: endedAt,
                duration: duration,
                offsetSeconds: 0,
                createdAt: now,
                updatedAt: now,
                transcriptionMode: .batch,
                retainAudioAfterBatch: retainAudioAfterBatch,
                batchCompletedAt: batchCompletedAt
            )
            try database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try session.insert(db)
            }
        }

        func removeFiles() {
            try? FileManager.default.removeItem(at: testRootURL)
        }

        func recordMicrophoneAudio(localeIdentifier: String = "ja_JP") async throws {
            let recorder = try BatchAudioRecordingSession(
                dbQueue: database.dbQueue,
                managedRootURL: managedRootURL,
                meetingId: meeting.id,
                recordingSessionId: session.id,
                recordingStartTime: now,
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
                locale: Locale(identifier: localeIdentifier),
                at: now
            )
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: recorder.targetFormat, frameCapacity: 160))
            buffer.frameLength = 160
            writer.appendBuffer(buffer)
            try await recorder.finish()
        }
    }
#endif
