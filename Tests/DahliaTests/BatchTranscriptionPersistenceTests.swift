import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BatchTranscriptionPersistenceTests {
        private typealias PersistenceState = (
            records: [TranscriptSegmentRecord],
            session: RecordingSessionRecord,
            meeting: MeetingRecord
        )

        @Test
        func completionIsAtomicAndRetryReplacesOnlyItsSession() throws {
            let now = Date(timeIntervalSince1970: 1_776_384_000)
            let fixture = try BatchAudioTestFixture(
                name: "Batch",
                endedAt: now.addingTimeInterval(10),
                duration: 10
            )
            defer { fixture.removeFiles() }
            let staleRecord = makeRecord(
                id: .v7(),
                meetingId: fixture.meeting.id,
                sessionId: fixture.session.id,
                text: "stale",
                now: now
            )
            try fixture.database.dbQueue.write { db in
                try staleRecord.insert(db)
            }

            let duplicateId = UUID.v7()
            let duplicateRecords = [
                makeRecord(id: duplicateId, meetingId: fixture.meeting.id, sessionId: fixture.session.id, text: "first", now: now),
                makeRecord(id: duplicateId, meetingId: fixture.meeting.id, sessionId: fixture.session.id, text: "duplicate", now: now),
            ]
            #expect(throws: (any Error).self) {
                try BatchTranscriptionPersistence.complete(
                    sessionId: fixture.session.id,
                    meetingId: fixture.meeting.id,
                    records: duplicateRecords,
                    completedAt: now.addingTimeInterval(20),
                    dbQueue: fixture.database.dbQueue
                )
            }

            let rolledBack = try fetchState(fixture)
            #expect(rolledBack.records.map(\.text) == ["stale"])
            #expect(rolledBack.session.batchCompletedAt == nil)
            #expect(rolledBack.meeting.status == .transcriptNotFound)

            let completedAt = now.addingTimeInterval(30)
            let finalRecord = makeRecord(
                id: .v7(),
                meetingId: fixture.meeting.id,
                sessionId: fixture.session.id,
                text: "final",
                now: now
            )
            try BatchTranscriptionPersistence.complete(
                sessionId: fixture.session.id,
                meetingId: fixture.meeting.id,
                records: [finalRecord],
                completedAt: completedAt,
                dbQueue: fixture.database.dbQueue
            )

            let completed = try fetchState(fixture)
            #expect(completed.records.map(\.text) == ["final"])
            #expect(completed.session.batchCompletedAt == completedAt)
            #expect(completed.meeting.status == .ready)
        }

        private func fetchState(_ fixture: BatchAudioTestFixture) throws -> PersistenceState {
            try fixture.database.dbQueue.read { db in
                let records = try TranscriptSegmentRecord
                    .filter(Column("sessionId") == fixture.session.id)
                    .fetchAll(db)
                let currentSession = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
                let currentMeeting = try MeetingRecord.fetchOne(db, key: fixture.meeting.id)
                let session = try #require(currentSession)
                let meeting = try #require(currentMeeting)
                return (records, session, meeting)
            }
        }

        private func makeRecord(
            id: UUID,
            meetingId: UUID,
            sessionId: UUID,
            text: String,
            now: Date
        ) -> TranscriptSegmentRecord {
            TranscriptSegmentRecord(
                id: id,
                meetingId: meetingId,
                sessionId: sessionId,
                startTime: now,
                endTime: now.addingTimeInterval(1),
                text: text,
                translatedText: nil,
                isConfirmed: true,
                speakerLabel: "mic"
            )
        }
    }
#endif
