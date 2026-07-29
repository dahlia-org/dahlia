import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    // swiftlint:disable:next type_body_length
    struct MeetingMetricsRevisionTests {
        @Test
        func realtimeWriterBumpsForSegmentsButNotTranslationOnlyUpdates() async throws {
            let (database, _, meeting, session) = try MeetingMetricsTestSupport.database()
            let writer = TranscriptPersistenceWriter(
                dbQueue: database.dbQueue,
                meetingId: meeting.id,
                recordingSessionId: session.id,
                persistencePolicy: .streaming
            )
            let segment = TranscriptSegment(
                startTime: MeetingMetricsTestSupport.baseDate,
                endTime: MeetingMetricsTestSupport.baseDate.addingTimeInterval(3),
                text: "発話",
                isConfirmed: true,
                speakerLabel: "mic"
            )

            try await writer.persist(.finalized(segment))
            let afterInsert = try currentRevision(meeting.id, database: database)
            try await writer.persist(.translation(
                sessionId: session.id,
                segmentID: segment.id,
                translatedText: "speech"
            ))
            let afterTranslation = try currentRevision(meeting.id, database: database)

            #expect(afterInsert == 1)
            #expect(afterTranslation == afterInsert)
        }

        @Test
        func batchReplacementAlwaysBumpsEvenWhenCountAndMaximumEndMatch() throws {
            let (database, _, meeting, session) = try MeetingMetricsTestSupport.database(
                meetingStatus: .processingTranscript,
                transcriptionMode: .batch
            )
            let original = MeetingMetricsTestSupport.record(
                meetingId: meeting.id,
                sessionId: session.id,
                start: 0,
                end: 10,
                text: "original"
            )
            let replacement = MeetingMetricsTestSupport.record(
                meetingId: meeting.id,
                sessionId: session.id,
                start: 2,
                end: 10,
                text: "replacement"
            )
            try database.dbQueue.write { db in
                try original.insert(db)
            }

            try BatchTranscriptionPersistence.complete(
                sessionId: session.id,
                meetingId: meeting.id,
                records: [replacement],
                completedAt: MeetingMetricsTestSupport.baseDate.addingTimeInterval(20),
                dbQueue: database.dbQueue
            )

            let persisted = try database.dbQueue.read { db in
                try TranscriptSegmentRecord
                    .filter(Column("sessionId") == session.id)
                    .fetchAll(db)
            }
            #expect(try currentRevision(meeting.id, database: database) == 1)
            #expect(persisted.map { $0.text } == ["replacement"])
            #expect(persisted.map { $0.endTime } == [original.endTime])
        }

        @Test
        func unprocessedDiscardBumpsAndLeavesPriorMetricsStale() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "MetricsUnprocessedDiscard",
                meetingStatus: .ready,
                endedAt: MeetingMetricsTestSupport.baseDate.addingTimeInterval(10),
                duration: 10
            )
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            try await seedSegmentAndMetrics(in: fixture)

            let discarded = try await BatchTranscriptionDiscardService.discardUnprocessedSessionSafely(
                id: fixture.session.id,
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL
            )
            let state = try metricsState(fixture.meeting.id, database: fixture.database)

            #expect(discarded)
            #expect(state.revision == 1)
            #expect(state.metricRevision == 0)
            #expect(state.segmentCount == 0)
        }

        @Test
        func failedDiscardBumpsAndLeavesPriorMetricsStale() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "MetricsFailedDiscard",
                meetingStatus: .ready,
                endedAt: MeetingMetricsTestSupport.baseDate.addingTimeInterval(10),
                duration: 10
            )
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            try await fixture.database.dbQueue.write { db in
                guard var session = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                session.batchLastError = "failed"
                try session.update(db)
            }
            try await seedSegmentAndMetrics(in: fixture)

            let discarded = try await BatchTranscriptionDiscardService.discardFailedSessionSafely(
                id: fixture.session.id,
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL
            )
            let state = try metricsState(fixture.meeting.id, database: fixture.database)

            #expect(discarded)
            #expect(state.revision == 1)
            #expect(state.metricRevision == 0)
            #expect(state.segmentCount == 0)
        }

        @Test
        func appendCancellationBumpsAndLeavesPriorMetricsStale() async throws {
            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            let service = try await MeetingPersistenceService.createAppending(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                existingMeetingId: meeting.id,
                recordingStartDate: MeetingMetricsTestSupport.baseDate.addingTimeInterval(60)
            )
            let segment = TranscriptSegment(
                startTime: MeetingMetricsTestSupport.baseDate.addingTimeInterval(60),
                endTime: MeetingMetricsTestSupport.baseDate.addingTimeInterval(63),
                text: "append",
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try await service.persist(.finalized(segment))
            let current = try currentRevision(meeting.id, database: database)
            #expect(try MeetingMetricsPersistence.save(
                makeResult(meetingId: meeting.id, revision: current),
                dbQueue: database.dbQueue
            ) == .saved)

            await service.cancel()
            let state = try metricsState(meeting.id, database: database)

            #expect(state.revision == current + 1)
            #expect(state.metricRevision == current)
            #expect(state.segmentCount == 0)
        }

        @Test
        func newMeetingCancellationCascadesMetricsWithoutRevisionBump() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/metrics-new-cancel-\(UUID.v7().uuidString)",
                name: "Metrics",
                createdAt: MeetingMetricsTestSupport.baseDate,
                lastOpenedAt: MeetingMetricsTestSupport.baseDate
            )
            try await database.dbQueue.write { db in try vault.insert(db) }
            let service = try await MeetingPersistenceService.createNew(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                vaultId: vault.id,
                projectId: nil,
                initialName: "New"
            )
            #expect(try MeetingMetricsPersistence.save(
                makeResult(meetingId: service.meetingId, revision: 0),
                dbQueue: database.dbQueue
            ) == .saved)

            await service.cancel()
            let counts = try await database.dbQueue.read { db in
                try (
                    MeetingRecord.filter(Column("id") == service.meetingId).fetchCount(db),
                    MeetingMetricsRecord.filter(Column("meetingId") == service.meetingId).fetchCount(db),
                    MeetingSourceMetricsRecord.filter(Column("meetingId") == service.meetingId).fetchCount(db)
                )
            }

            #expect(counts.0 == 0)
            #expect(counts.1 == 0)
            #expect(counts.2 == 0)
        }

        @Test
        func zeroRowDiscardAndAppendRollbackDoNotBump() async throws {
            let unprocessed = try BatchAudioTestFixture(
                name: "MetricsZeroUnprocessed",
                endedAt: MeetingMetricsTestSupport.baseDate.addingTimeInterval(10),
                duration: 10
            )
            defer { unprocessed.removeFiles() }
            try await unprocessed.recordMicrophoneAudio()
            #expect(try await BatchTranscriptionDiscardService.discardUnprocessedSessionSafely(
                id: unprocessed.session.id,
                dbQueue: unprocessed.database.dbQueue,
                managedRootURL: unprocessed.managedRootURL
            ))
            #expect(try currentRevision(unprocessed.meeting.id, database: unprocessed.database) == 0)

            let failed = try BatchAudioTestFixture(
                name: "MetricsZeroFailed",
                endedAt: MeetingMetricsTestSupport.baseDate.addingTimeInterval(10),
                duration: 10
            )
            defer { failed.removeFiles() }
            try await failed.recordMicrophoneAudio()
            try await failed.database.dbQueue.write { db in
                guard var session = try RecordingSessionRecord.fetchOne(db, key: failed.session.id) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                session.batchLastError = "failed"
                try session.update(db)
            }
            #expect(try await BatchTranscriptionDiscardService.discardFailedSessionSafely(
                id: failed.session.id,
                dbQueue: failed.database.dbQueue,
                managedRootURL: failed.managedRootURL
            ))
            #expect(try currentRevision(failed.meeting.id, database: failed.database) == 0)

            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            let service = try await MeetingPersistenceService.createAppending(
                store: TranscriptStore(),
                dbQueue: database.dbQueue,
                existingMeetingId: meeting.id
            )
            await service.cancel()
            #expect(try currentRevision(meeting.id, database: database) == 0)
        }

        @Test
        func staleCompareAndSwapLeavesExistingRowsByteForByteUnchanged() throws {
            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            let initial = makeResult(meetingId: meeting.id, revision: 0)
            #expect(try MeetingMetricsPersistence.save(initial, dbQueue: database.dbQueue) == .saved)
            let before = try storedMetrics(meeting.id, database: database)
            try database.dbQueue.write { db in
                try MeetingTranscriptRevision.bump(meetingId: meeting.id, in: db)
            }
            let stale = makeResult(meetingId: meeting.id, revision: 0, conversationTalkSeconds: 999)

            let outcome = try MeetingMetricsPersistence.save(stale, dbQueue: database.dbQueue)
            let after = try storedMetrics(meeting.id, database: database)

            #expect(outcome == .revisionChanged(1))
            #expect(after.metric == before.metric)
            #expect(after.sources == before.sources)
        }

        @Test
        func successfulCompareAndSwapReplacesOldSourceRows() throws {
            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            #expect(try MeetingMetricsPersistence.save(
                makeResult(meetingId: meeting.id, revision: 0),
                dbQueue: database.dbQueue
            ) == .saved)
            let replacement = MeetingMetricsResult(
                meetingId: meeting.id,
                metricsVersion: MeetingMetricsConstants.metricsVersion,
                transcriptRevision: 0,
                conversationTalkSeconds: 80,
                overlapSeconds: nil,
                talkBalance: nil,
                confirmedSegmentCount: 2,
                validSegmentCount: 2,
                invalidDurationSegmentCount: 0,
                unknownSourceSegmentCount: 0,
                totalCharacterCount: 40,
                validCharacterCount: 40,
                unknownSourceCharacterCount: 0,
                sourceRows: [sourceRow(meetingId: meeting.id, source: .microphone, seconds: 80, characters: 40)]
            )

            #expect(try MeetingMetricsPersistence.save(replacement, dbQueue: database.dbQueue) == .saved)
            let stored = try storedMetrics(meeting.id, database: database)

            #expect(stored.metric?.conversationTalkSeconds == 80)
            #expect(stored.sources.count == 1)
            #expect(stored.sources.first?.source == .microphone)
            #expect(stored.sources.first?.characterCount == 40)
        }

        private func seedSegmentAndMetrics(in fixture: BatchAudioTestFixture) async throws {
            let record = MeetingMetricsTestSupport.record(
                meetingId: fixture.meeting.id,
                sessionId: fixture.session.id,
                start: 0,
                end: 4
            )
            try await fixture.database.dbQueue.write { db in try record.insert(db) }
            #expect(try MeetingMetricsPersistence.save(
                makeResult(meetingId: fixture.meeting.id, revision: 0),
                dbQueue: fixture.database.dbQueue
            ) == .saved)
        }

        private func currentRevision(_ meetingId: UUID, database: AppDatabaseManager) throws -> Int64 {
            try database.dbQueue.read { db in
                try MeetingTranscriptRevision.current(meetingId: meetingId, in: db)
            }
        }

        private func metricsState(
            _ meetingId: UUID,
            database: AppDatabaseManager
        ) throws -> (revision: Int64, metricRevision: Int64?, segmentCount: Int) {
            try database.dbQueue.read { db in
                try (
                    MeetingTranscriptRevision.current(meetingId: meetingId, in: db),
                    MeetingMetricsRecord.fetchOne(db, key: meetingId)?.transcriptRevision,
                    TranscriptSegmentRecord.filter(Column("meetingId") == meetingId).fetchCount(db)
                )
            }
        }

        private func storedMetrics(
            _ meetingId: UUID,
            database: AppDatabaseManager
        ) throws -> (metric: MeetingMetricsRecord?, sources: [MeetingSourceMetricsRecord]) {
            try database.dbQueue.read { db in
                try (
                    MeetingMetricsRecord.fetchOne(db, key: meetingId),
                    MeetingSourceMetricsRecord
                        .filter(Column("meetingId") == meetingId)
                        .order(Column("source"))
                        .fetchAll(db)
                )
            }
        }

        private func makeResult(
            meetingId: UUID,
            revision: Int64,
            conversationTalkSeconds: Double = 180
        ) -> MeetingMetricsResult {
            MeetingMetricsResult(
                meetingId: meetingId,
                metricsVersion: MeetingMetricsConstants.metricsVersion,
                transcriptRevision: revision,
                conversationTalkSeconds: conversationTalkSeconds,
                overlapSeconds: 12,
                talkBalance: 0.55,
                confirmedSegmentCount: 8,
                validSegmentCount: 8,
                invalidDurationSegmentCount: 0,
                unknownSourceSegmentCount: 0,
                totalCharacterCount: 600,
                validCharacterCount: 600,
                unknownSourceCharacterCount: 0,
                sourceRows: [
                    sourceRow(meetingId: meetingId, source: .microphone, seconds: 99, characters: 360),
                    sourceRow(meetingId: meetingId, source: .system, seconds: 81, characters: 240),
                ]
            )
        }

        private func sourceRow(
            meetingId: UUID,
            source: MetricsSource,
            seconds: Double,
            characters: Int
        ) -> MeetingSourceMetricsRow {
            MeetingSourceMetricsRow(
                meetingId: meetingId,
                source: source,
                speakingSeconds: seconds,
                characterCount: characters,
                cjkCharacterCount: characters,
                turnCount: 4,
                charactersPerMinute: Double(characters) / (seconds / 60)
            )
        }
    }
#endif
