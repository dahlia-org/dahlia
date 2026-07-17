import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingPersistenceStopTests {
        @Test
        func stopCompletesAfterFinalizedEventsArePersisted() async throws {
            let fixture = try makeDatabase()
            let store = TranscriptStore()
            let startDate = Date(timeIntervalSince1970: 1_776_384_000)
            store.recordingStartTime = startDate
            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: fixture.database.dbQueue,
                vaultId: fixture.vault.id,
                projectId: nil,
                initialName: "Final segment"
            )
            let segment = TranscriptSegment(
                startTime: startDate,
                text: "Persisted at stop",
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try await service.persist(.finalized(segment))

            let result = await service.stop()

            let persisted = try await fixture.database.dbQueue.read { db in
                try TranscriptSegmentRecord.fetchOne(db, key: segment.id)
            }
            #expect(result.succeeded)
            #expect(persisted?.sessionId == service.recordingSessionId)
            #expect(persisted?.text == segment.text)
        }

        @Test
        func stopReportsSessionPersistenceFailure() async throws {
            let fixture = try makeDatabase()
            let store = TranscriptStore()
            store.recordingStartTime = Date(timeIntervalSince1970: 1_776_384_000)
            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: fixture.database.dbQueue,
                vaultId: fixture.vault.id,
                projectId: nil,
                initialName: "Persistence failure"
            )
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_recording_session_stop
                BEFORE UPDATE OF endedAt ON recording_sessions
                BEGIN
                    SELECT RAISE(ABORT, 'forced stop failure');
                END
                """)
            }

            let result = await service.stop()

            let session = try await fixture.database.dbQueue.read { db in
                let record = try RecordingSessionRecord.fetchOne(db, key: service.recordingSessionId)
                return try #require(record)
            }
            #expect(!result.succeeded)
            #expect(result.failureMessage != nil)
            #expect(session.endedAt == nil)
            #expect(session.duration == nil)
        }

        @Test
        func appendStopDoesNotAssignLegacySegmentsToNewSession() async throws {
            let fixture = try makeDatabase()
            let meetingId = UUID.v7()
            let legacySegment = TranscriptSegment(
                id: .v7(),
                sessionId: nil,
                startTime: fixture.vault.createdAt,
                text: "Legacy transcript",
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try await fixture.database.dbQueue.write { db in
                try MeetingRecord(
                    id: meetingId,
                    vaultId: fixture.vault.id,
                    projectId: nil,
                    name: "Legacy meeting",
                    status: .ready,
                    createdAt: fixture.vault.createdAt,
                    updatedAt: fixture.vault.createdAt
                ).insert(db)
                try TranscriptSegmentRecord(from: legacySegment, meetingId: meetingId).insert(db)
            }
            let store = TranscriptStore()
            store.loadSegments([legacySegment])
            let service = try MeetingPersistenceService(
                store: store,
                dbQueue: fixture.database.dbQueue,
                existingMeetingId: meetingId,
                existingSegmentIds: [legacySegment.id],
                recordingStartDate: .now
            )
            let newSegment = TranscriptSegment(
                startTime: .now,
                text: "New transcript",
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try await service.persist(.finalized(newSegment))

            let result = await service.stop()

            let records = try await fixture.database.dbQueue.read { db in
                try TranscriptSegmentRecord.order(Column("startTime").asc).fetchAll(db)
            }
            #expect(result.succeeded)
            #expect(records.first(where: { $0.id == legacySegment.id })?.sessionId == nil)
            #expect(records.first(where: { $0.id == newSegment.id })?.sessionId == service.recordingSessionId)
        }

        private func makeDatabase() throws -> (database: AppDatabaseManager, vault: VaultRecord) {
            let database = try AppDatabaseManager(path: ":memory:")
            let createdAt = Date(timeIntervalSince1970: 1_776_380_000)
            let vault = VaultRecord(
                id: .v7(),
                path: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).path,
                name: "Persistence Stop Test Vault",
                createdAt: createdAt,
                lastOpenedAt: createdAt
            )
            try database.dbQueue.write { db in
                try vault.insert(db)
            }
            return (database, vault)
        }
    }
#endif
