import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingPersistenceStopTests {
        @Test
        func stopPersistsFinalConfirmedSegmentsBeforeReportingSuccess() throws {
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
            store.addSegment(segment)

            let result = service.stop()

            let persisted = try fixture.database.dbQueue.read { db in
                try TranscriptSegmentRecord.fetchOne(db, key: segment.id)
            }
            #expect(result.succeeded)
            #expect(persisted?.sessionId == service.recordingSessionId)
            #expect(persisted?.text == segment.text)
        }

        @Test
        func stopReportsSessionPersistenceFailure() throws {
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
            try fixture.database.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_recording_session_stop
                BEFORE UPDATE OF endedAt ON recording_sessions
                BEGIN
                    SELECT RAISE(ABORT, 'forced stop failure');
                END
                """)
            }

            let result = service.stop()

            let session = try fixture.database.dbQueue.read { db in
                let record = try RecordingSessionRecord.fetchOne(db, key: service.recordingSessionId)
                return try #require(record)
            }
            #expect(!result.succeeded)
            #expect(result.failureMessage != nil)
            #expect(session.endedAt == nil)
            #expect(session.duration == nil)
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
