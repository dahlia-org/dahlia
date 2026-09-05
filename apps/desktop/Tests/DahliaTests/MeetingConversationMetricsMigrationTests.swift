import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingConversationMetricsMigrationTests {
        @Test
        // swiftlint:disable:next function_body_length
        func migrationFromV30PreservesExistingRowsAndAddsCascadeTables() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v30_organizationDescription")
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let vault = VaultRecord(
                id: UUID(),
                path: "/tmp/conversation-metrics-migration",
                name: "Vault",
                createdAt: now,
                lastOpenedAt: now
            )
            let meeting = MeetingRecord(
                id: UUID(),
                vaultId: vault.id,
                projectId: nil,
                name: "Preserved",
                createdAt: now,
                updatedAt: now
            )
            let segmentID = UUID()
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

            try AppDatabaseManager.migrator.migrate(queue)

            let result = try queue.read { db in
                try (
                    MeetingRecord.fetchOne(db, key: meeting.id),
                    TranscriptSegmentRecord.fetchOne(db, key: segmentID),
                    db.tableExists(MeetingConversationMetricsRecord.databaseTableName),
                    db.tableExists(MeetingConversationSourceMetricsRecord.databaseTableName)
                )
            }

            #expect(result.0?.name == "Preserved")
            #expect(result.1?.text == "Preserved")
            #expect(result.2)
            #expect(result.3)
        }
    }
#endif
