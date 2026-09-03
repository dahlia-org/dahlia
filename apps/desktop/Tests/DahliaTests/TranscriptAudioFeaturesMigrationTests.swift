import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct TranscriptAudioFeaturesMigrationTests {
        @Test
        func migrationFromV31PreservesTranscriptAndAddsNullableFeatureColumns() throws {
            let (queue, segmentID) = try makeV31Database()

            try AppDatabaseManager.migrator.migrate(queue)

            let result = try queue.read { db in
                try (
                    TranscriptSegmentRecord.fetchOne(db, key: segmentID),
                    String.fetchAll(
                        db,
                        sql: """
                        SELECT name
                        FROM pragma_table_info('transcript_segments')
                        WHERE name LIKE 'audio%'
                        ORDER BY cid
                        """
                    )
                )
            }

            #expect(result.0?.text == "Preserved")
            #expect(result.0?.audioFeatures == nil)
            #expect(result.1 == [
                "audioFeatureVersion",
                "audioActiveRmsDecibels",
                "audioMedianPitchHertz",
                "audioVoicedFrameRatio",
                "audioPitchSpreadHertz",
                "audioSource",
            ])
        }

        private func makeV31Database() throws -> (DatabaseQueue, UUID) {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v31_meetingConversationMetrics")
            let now = Date(timeIntervalSince1970: 1_776_384_000)
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/transcript-audio-features-migration",
                name: "Vault",
                createdAt: now,
                lastOpenedAt: now
            )
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: "Preserved",
                createdAt: now,
                updatedAt: now
            )
            let segmentID = UUID.v7()
            try queue.write { db in
                try insertLegacyVault(vault, in: db)
                try db.execute(
                    sql: """
                    INSERT INTO meetings (id, vaultId, projectId, name, status, duration, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        meeting.id, meeting.vaultId, meeting.projectId, meeting.name, meeting.status,
                        meeting.duration, meeting.createdAt, meeting.updatedAt,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segments (
                        id, meetingId, startTime, endTime, text,
                        translatedText, isConfirmed, speakerLabel
                    )
                    VALUES (?, ?, ?, ?, ?, NULL, 1, ?)
                    """,
                    arguments: [
                        segmentID,
                        meeting.id,
                        now,
                        now.addingTimeInterval(1),
                        "Preserved",
                        RecordingAudioSource.microphone.audioSource,
                    ]
                )
            }
            return (queue, segmentID)
        }
    }
#endif
