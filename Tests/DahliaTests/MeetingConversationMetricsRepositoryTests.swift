import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingConversationMetricsRepositoryTests {
        @Test
        func lazyRebuildPersistsBothSourcesAndReusesMatchingFingerprint() throws {
            let fixture = try Fixture()
            try fixture.insertSessionAndSegments()
            let firstComputedAt = fixture.baseDate.addingTimeInterval(100)
            let secondComputedAt = fixture.baseDate.addingTimeInterval(200)

            let first = try fixture.repository.loadOrRebuildConversationMetrics(
                meetingId: fixture.meeting.id,
                computedAt: firstComputedAt
            )
            let second = try fixture.repository.loadOrRebuildConversationMetrics(
                meetingId: fixture.meeting.id,
                computedAt: secondComputedAt
            )
            let saved = try fixture.manager.dbQueue.read { db in
                try MeetingConversationSourceMetricsRecord
                    .filter(Column("meetingId") == fixture.meeting.id)
                    .fetchAll(db)
            }

            #expect(first.computedAt == firstComputedAt)
            #expect(second.computedAt == firstComputedAt)
            #expect(Set(saved.map(\.source)) == Set([RecordingAudioSource.microphone, .system]))
            #expect(first.longestMonologue == .init(source: .microphone, start: 0, end: 10))
            #expect(second.longestMonologue == first.longestMonologue)
        }

        @Test
        func pagedTranscriptReadIncludesEverySegment() throws {
            let fixture = try Fixture()
            try fixture.insertMicrophoneSegments(count: 501)

            let metrics = try fixture.repository.loadOrRebuildConversationMetrics(
                meetingId: fixture.meeting.id
            )

            #expect(metrics.source(.microphone).segmentCount == 501)
        }

        @Test
        func transcriptReplacementRebuildsButMeetingMetadataAndTranslationDoNot() throws {
            let fixture = try Fixture()
            let segmentId = try fixture.insertSessionAndSegments()
            let firstComputedAt = fixture.baseDate.addingTimeInterval(100)
            let metadataComputedAt = fixture.baseDate.addingTimeInterval(200)
            let replacementComputedAt = fixture.baseDate.addingTimeInterval(300)
            let first = try fixture.repository.loadOrRebuildConversationMetrics(
                meetingId: fixture.meeting.id,
                computedAt: firstComputedAt
            )

            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE meetings
                    SET name = ?, description = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: ["Renamed", "New description", metadataComputedAt, fixture.meeting.id]
                )
                try TranscriptSegmentRecord.updateTranslatedText("translation", id: segmentId, in: db)
            }
            let metadataOnly = try fixture.repository.loadOrRebuildConversationMetrics(
                meetingId: fixture.meeting.id,
                computedAt: metadataComputedAt
            )

            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE transcript_segments SET text = ? WHERE id = ?",
                    arguments: ["same-size replacement", segmentId]
                )
            }
            let replaced = try fixture.repository.loadOrRebuildConversationMetrics(
                meetingId: fixture.meeting.id,
                computedAt: replacementComputedAt
            )

            #expect(metadataOnly.inputFingerprint == first.inputFingerprint)
            #expect(metadataOnly.computedAt == firstComputedAt)
            #expect(replaced.inputFingerprint != first.inputFingerprint)
            #expect(replaced.computedAt == replacementComputedAt)
        }

        @Test
        func definitionVersionMismatchForcesRebuild() throws {
            let fixture = try Fixture()
            try fixture.insertSessionAndSegments()
            _ = try fixture.repository.loadOrRebuildConversationMetrics(
                meetingId: fixture.meeting.id,
                computedAt: fixture.baseDate
            )
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE meeting_conversation_metrics
                    SET calculationVersion = 0
                    WHERE meetingId = ?
                    """,
                    arguments: [fixture.meeting.id]
                )
            }
            let rebuiltAt = fixture.baseDate.addingTimeInterval(60)

            let rebuilt = try fixture.repository.loadOrRebuildConversationMetrics(
                meetingId: fixture.meeting.id,
                computedAt: rebuiltAt
            )
            let savedVersion = try fixture.manager.dbQueue.read { db in
                try MeetingConversationMetricsRecord
                    .fetchOne(db, key: fixture.meeting.id)?
                    .calculationVersion
            }

            #expect(rebuilt.computedAt == rebuiltAt)
            #expect(savedVersion == MeetingConversationMetrics.calculationVersion)
        }

        @Test
        func deletingMeetingCascadesConversationMetrics() throws {
            let fixture = try Fixture()
            try fixture.insertSessionAndSegments()
            _ = try fixture.repository.loadOrRebuildConversationMetrics(meetingId: fixture.meeting.id)

            try fixture.manager.dbQueue.write { db in
                _ = try MeetingRecord.deleteOne(db, key: fixture.meeting.id)
            }
            let counts = try fixture.manager.dbQueue.read { db in
                (
                    try MeetingConversationMetricsRecord.fetchCount(db),
                    try MeetingConversationSourceMetricsRecord.fetchCount(db)
                )
            }

            #expect(counts.0 == 0)
            #expect(counts.1 == 0)
        }

        private struct Fixture {
            let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
            let manager: AppDatabaseManager
            let repository: MeetingRepository
            let meeting: MeetingRecord

            init() throws {
                manager = try AppDatabaseManager(path: ":memory:")
                repository = MeetingRepository(dbQueue: manager.dbQueue)
                let vault = VaultRecord(
                    id: UUID(),
                    path: "/tmp/conversation-metrics-tests",
                    name: "Test",
                    createdAt: baseDate,
                    lastOpenedAt: baseDate
                )
                meeting = MeetingRecord(
                    id: UUID(),
                    vaultId: vault.id,
                    projectId: nil,
                    name: "Meeting",
                    duration: 30,
                    createdAt: baseDate,
                    updatedAt: baseDate
                )
                try manager.dbQueue.write { db in
                    try vault.insert(db)
                    try meeting.insert(db)
                }
            }

            @discardableResult
            func insertSessionAndSegments() throws -> UUID {
                let session = RecordingSessionRecord(
                    id: UUID(),
                    meetingId: meeting.id,
                    startedAt: baseDate,
                    endedAt: baseDate.addingTimeInterval(30),
                    duration: 30,
                    offsetSeconds: 0,
                    createdAt: baseDate,
                    updatedAt: baseDate
                )
                let microphoneId = UUID()
                try manager.dbQueue.write { db in
                    try session.insert(db)
                    try TranscriptSegmentRecord(
                        id: microphoneId,
                        meetingId: meeting.id,
                        sessionId: session.id,
                        startTime: baseDate,
                        endTime: baseDate.addingTimeInterval(10),
                        text: "hello",
                        translatedText: nil,
                        isConfirmed: true,
                        speakerLabel: RecordingAudioSource.microphone.speakerLabel
                    )
                    .insert(db)
                    try TranscriptSegmentRecord(
                        id: UUID(),
                        meetingId: meeting.id,
                        sessionId: session.id,
                        startTime: baseDate.addingTimeInterval(5),
                        endTime: baseDate.addingTimeInterval(12),
                        text: "world",
                        translatedText: nil,
                        isConfirmed: true,
                        speakerLabel: RecordingAudioSource.system.speakerLabel
                    )
                    .insert(db)
                }
                return microphoneId
            }

            func insertMicrophoneSegments(count: Int) throws {
                let session = RecordingSessionRecord(
                    id: UUID(),
                    meetingId: meeting.id,
                    startedAt: baseDate,
                    endedAt: baseDate.addingTimeInterval(30),
                    duration: 30,
                    offsetSeconds: 0,
                    createdAt: baseDate,
                    updatedAt: baseDate
                )
                try manager.dbQueue.write { db in
                    try session.insert(db)
                    for _ in 0 ..< count {
                        try TranscriptSegmentRecord(
                            id: UUID(),
                            meetingId: meeting.id,
                            sessionId: session.id,
                            startTime: baseDate,
                            endTime: baseDate.addingTimeInterval(1),
                            text: "segment",
                            translatedText: nil,
                            isConfirmed: true,
                            speakerLabel: RecordingAudioSource.microphone.speakerLabel
                        )
                        .insert(db)
                    }
                }
            }
        }
    }
#endif
