import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingConversationMetricsMigrationTests {
        @Test
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
                try vault.insert(db)
                try meeting.insert(db)
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
                        RecordingAudioSource.microphone.speakerLabel,
                    ]
                )
            }

            try AppDatabaseManager.migrator.migrate(queue)

            let result = try queue.read { db in
                (
                    try MeetingRecord.fetchOne(db, key: meeting.id),
                    try TranscriptSegmentRecord.fetchOne(db, key: segmentID),
                    try db.tableExists(MeetingConversationMetricsRecord.databaseTableName),
                    try db.tableExists(MeetingConversationSourceMetricsRecord.databaseTableName)
                )
            }

            #expect(result.0?.name == "Preserved")
            #expect(result.1?.text == "Preserved")
            #expect(result.2)
            #expect(result.3)
        }
    }
#endif
