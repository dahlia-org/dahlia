import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingMetricsMigrationTests {
        @Test
        func v30UpgradePreservesExistingRowsAndAddsZeroRevision() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v30_organizationDescription")
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/meeting-metrics-migration",
                name: "Migration",
                createdAt: MeetingMetricsTestSupport.baseDate,
                lastOpenedAt: MeetingMetricsTestSupport.baseDate
            )
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: "Migration",
                status: .ready,
                duration: 10,
                createdAt: MeetingMetricsTestSupport.baseDate,
                updatedAt: MeetingMetricsTestSupport.baseDate
            )
            let session = RecordingSessionRecord(
                id: .v7(),
                meetingId: meeting.id,
                startedAt: MeetingMetricsTestSupport.baseDate,
                endedAt: MeetingMetricsTestSupport.baseDate.addingTimeInterval(10),
                duration: 10,
                offsetSeconds: 0,
                createdAt: MeetingMetricsTestSupport.baseDate,
                updatedAt: MeetingMetricsTestSupport.baseDate
            )
            let segment = MeetingMetricsTestSupport.record(
                meetingId: meeting.id,
                sessionId: session.id,
                start: 0,
                end: 10
            )
            try queue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try session.insert(db)
                try segment.insert(db)
            }

            try AppDatabaseManager.migrator.migrate(queue)

            let preserved = try queue.read { db in
                (
                    try VaultRecord.fetchCount(db),
                    try MeetingRecord.fetchCount(db),
                    try RecordingSessionRecord.fetchCount(db),
                    try TranscriptSegmentRecord.fetchCount(db),
                    try MeetingTranscriptRevision.current(meetingId: meeting.id, in: db)
                )
            }
            #expect(preserved.0 == 1)
            #expect(preserved.1 == 1)
            #expect(preserved.2 == 1)
            #expect(preserved.3 == 1)
            #expect(preserved.4 == 0)
        }

        @Test
        func emptyDatabaseReachesSchema31() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let result = try database.dbQueue.read { db in
                (
                    try db.tableExists(MeetingMetricsRecord.databaseTableName),
                    try db.tableExists(MeetingSourceMetricsRecord.databaseTableName),
                    try AppDatabaseManager.migrator.hasCompletedMigrations(db),
                    try AppDatabaseManager.hasExpectedCurrentSchema(db)
                )
            }
            #expect(AppDatabaseManager.currentMigrationIdentifier == "v31_meetingMetrics")
            #expect(AppDatabaseManager.currentSchemaVersion == 31)
            #expect(result.0 && result.1 && result.2 && result.3)
        }

        @Test
        func sourceValuesRoundTripAndCheckRejectsOther() throws {
            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            try database.dbQueue.write { db in
                for source in MetricsSource.allCases {
                    try MeetingSourceMetricsRecord(MeetingSourceMetricsRow(
                        meetingId: meeting.id,
                        source: source,
                        speakingSeconds: 1,
                        characterCount: 1,
                        cjkCharacterCount: 0,
                        turnCount: 1,
                        charactersPerMinute: nil
                    )).insert(db)
                }
            }
            let sources = try database.dbQueue.read { db in
                try MeetingSourceMetricsRecord.fetchAll(db).map(\.source)
            }
            #expect(Set(sources) == Set(MetricsSource.allCases))
            #expect(throws: DatabaseError.self) {
                try database.dbQueue.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO meeting_source_metrics (
                            meetingId, source, speakingSeconds, characterCount,
                            cjkCharacterCount, turnCount, charactersPerMinute
                        ) VALUES (?, 'other', 1, 1, 0, 1, NULL)
                        """,
                        arguments: [meeting.id]
                    )
                }
            }
        }

        @Test
        func nullableValuesAndCascadeDeletionArePreserved() throws {
            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            let result = MeetingMetricsTestSupport.result(overlapSeconds: nil, talkBalance: nil)
            let persisted = MeetingMetricsResult(
                meetingId: meeting.id,
                metricsVersion: result.metricsVersion,
                transcriptRevision: 0,
                conversationTalkSeconds: result.conversationTalkSeconds,
                overlapSeconds: nil,
                talkBalance: nil,
                confirmedSegmentCount: result.confirmedSegmentCount,
                validSegmentCount: result.validSegmentCount,
                invalidDurationSegmentCount: result.invalidDurationSegmentCount,
                unknownSourceSegmentCount: result.unknownSourceSegmentCount,
                totalCharacterCount: result.totalCharacterCount,
                validCharacterCount: result.validCharacterCount,
                unknownSourceCharacterCount: result.unknownSourceCharacterCount,
                sourceRows: [
                    MeetingSourceMetricsRow(
                        meetingId: meeting.id,
                        source: .microphone,
                        speakingSeconds: 10,
                        characterCount: 10,
                        cjkCharacterCount: 10,
                        turnCount: 1,
                        charactersPerMinute: nil
                    ),
                ],
            )
            _ = try MeetingMetricsPersistence.save(persisted, dbQueue: database.dbQueue)
            let nullable = try database.dbQueue.read { db in
                (
                    try MeetingMetricsRecord.fetchOne(db, key: meeting.id),
                    try MeetingSourceMetricsRecord.fetchAll(db).first
                )
            }
            #expect(nullable.0?.overlapSeconds == nil)
            #expect(nullable.0?.talkBalance == nil)
            #expect(nullable.1?.charactersPerMinute == nil)

            try database.dbQueue.write { db in
                _ = try MeetingRecord.deleteOne(db, key: meeting.id)
            }
            let counts = try database.dbQueue.read { db in
                try (MeetingMetricsRecord.fetchCount(db), MeetingSourceMetricsRecord.fetchCount(db))
            }
            #expect(counts.0 == 0)
            #expect(counts.1 == 0)
        }

        @Test
        func migrationBodyIsRerunnable() throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v30_organizationDescription")
            try queue.write { db in
                try MeetingMetricsMigration.migrate(in: db)
                try MeetingMetricsMigration.migrate(in: db)
            }
            let columns = try queue.read { db in
                try db.columns(in: MeetingRecord.databaseTableName).filter { $0.name == "transcriptRevision" }
            }
            #expect(columns.count == 1)
        }
    }
#endif
