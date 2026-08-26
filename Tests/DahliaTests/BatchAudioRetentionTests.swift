import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchAudioRetentionTests {
        enum ExcludedSessionState: Sendable {
            case missingEnd
            case failedSegment
            case discarded
            case retranscriptionPending
        }

        private let day: TimeInterval = 24 * 60 * 60

        @Test
        func foreverDoesNotPurgeCompletedAudio() async throws {
            let fixture = try completedFixture(name: "Forever")
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let coordinator = makeCoordinator(fixture, period: .forever)

            await coordinator.refreshExpiredAudio(now: fixture.now.addingTimeInterval(day * 30))

            #expect(try await segmentState(fixture) == .ready)
        }

        @Test
        func finiteRetentionStartsAfterBothRecordingAndTranscriptionComplete() async throws {
            let fixture = try completedFixture(name: "Deadline")
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let coordinator = makeCoordinator(fixture, period: .oneDay)
            let endedAt = try #require(fixture.session.endedAt)
            let completedAt = try #require(fixture.session.batchCompletedAt)

            await coordinator.refreshExpiredAudio(now: endedAt.addingTimeInterval(day))
            #expect(try await segmentState(fixture) == .ready)

            await coordinator.refreshExpiredAudio(now: completedAt.addingTimeInterval(day))
            #expect(try await segmentState(fixture) == .purged)
        }

        @Test
        func retentionPurgeRevalidatesRetranscriptionBeforeRecordingIntent() async throws {
            let fixture = try completedFixture(name: "RetranscriptionRace")
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let completedAt = try #require(fixture.session.batchCompletedAt)
            let cutoff = completedAt.addingTimeInterval(day)
            try await fixture.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE recording_sessions SET batchLastAttemptAt = ? WHERE id = ?",
                    arguments: [completedAt.addingTimeInterval(1), fixture.session.id]
                )
            }
            let store = try RecordingAudioStore(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL
            )

            try await store.requestRetentionPurge(sessionId: fixture.session.id, cutoff: cutoff)

            #expect(try await segmentState(fixture) == .ready)
        }

        @Test
        func meetingStartDoesNotShortenAnAppendedSessionRetention() async throws {
            let fixture = try completedFixture(name: "Appended")
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            try await fixture.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE meetings SET recordingStartedAt = ? WHERE id = ?",
                    arguments: [fixture.now.addingTimeInterval(-day * 30), fixture.meeting.id]
                )
            }
            let coordinator = makeCoordinator(fixture, period: .oneDay)
            let endedAt = try #require(fixture.session.endedAt)

            await coordinator.refreshExpiredAudio(now: endedAt.addingTimeInterval(day - 1))

            #expect(try await segmentState(fixture) == .ready)
        }

        @Test
        func shorteningRetentionReevaluatesExistingAudio() async throws {
            let fixture = try completedFixture(name: "Shortened")
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let coordinator = makeCoordinator(fixture, period: .forever)

            await coordinator.updateAudioRetentionPeriod(
                .oneDay,
                now: fixture.now.addingTimeInterval(day * 30)
            )

            #expect(try await segmentState(fixture) == .purged)
        }

        @Test
        func changingToForeverCancelsFutureEligibility() async throws {
            let fixture = try completedFixture(name: "Extended")
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            let coordinator = makeCoordinator(fixture, period: .oneDay)

            await coordinator.updateAudioRetentionPeriod(.forever)
            await coordinator.refreshExpiredAudio(now: fixture.now.addingTimeInterval(day * 30))

            #expect(try await segmentState(fixture) == .ready)
        }

        @Test(arguments: [ExcludedSessionState.missingEnd, .failedSegment, .discarded, .retranscriptionPending])
        func excludesUnsafeOrInactiveSessions(state: ExcludedSessionState) async throws {
            let fixture = try completedFixture(name: "Excluded-\(state)")
            defer { fixture.removeFiles() }
            try await fixture.recordMicrophoneAudio()
            try await fixture.database.dbQueue.write { db in
                switch state {
                case .missingEnd:
                    try db.execute(sql: "UPDATE recording_sessions SET endedAt = NULL WHERE id = ?", arguments: [fixture.session.id])
                case .failedSegment:
                    try db.execute(
                        sql: "UPDATE recording_audio_segments SET state = ? WHERE recordingSessionId = ?",
                        arguments: [RecordingAudioSegmentState.failed.rawValue, fixture.session.id]
                    )
                case .discarded:
                    try db.execute(
                        sql: "UPDATE recording_sessions SET batchDiscardedAt = ? WHERE id = ?",
                        arguments: [fixture.now, fixture.session.id]
                    )
                case .retranscriptionPending:
                    try db.execute(
                        sql: "UPDATE recording_sessions SET batchLastAttemptAt = ? WHERE id = ?",
                        arguments: [fixture.now.addingTimeInterval(120), fixture.session.id]
                    )
                }
            }
            let coordinator = makeCoordinator(fixture, period: .oneDay)

            await coordinator.refreshExpiredAudio(now: fixture.now.addingTimeInterval(day * 30))

            #expect(try await segmentState(fixture) != .purged)
        }

        private func completedFixture(name: String) throws -> BatchAudioTestFixture {
            try BatchAudioTestFixture(
                name: name,
                meetingStatus: .ready,
                endedAt: Date(timeIntervalSince1970: 1_776_384_060),
                duration: 60,
                batchCompletedAt: Date(timeIntervalSince1970: 1_776_384_070)
            )
        }

        private func makeCoordinator(
            _ fixture: BatchAudioTestFixture,
            period: BatchAudioRetentionPeriod
        ) -> BatchTranscriptionCoordinator {
            BatchTranscriptionCoordinator(
                dbQueue: fixture.database.dbQueue,
                managedRootURL: fixture.managedRootURL,
                audioRetentionPeriod: period,
                onStateChange: { _ in }
            )
        }

        private func segmentState(_ fixture: BatchAudioTestFixture) async throws -> RecordingAudioSegmentState {
            try await fixture.database.dbQueue.read { db in
                try #require(try RecordingAudioSegmentRecord.fetchOne(db)?.state)
            }
        }
    }

#endif
