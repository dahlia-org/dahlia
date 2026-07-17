#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct TranscriptPersistenceRetryTests {
        @Test
        func stopRetriesEventsRetainedAfterATemporaryDatabaseFailure() async throws {
            let fixture = try makePersistenceFixture()
            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: fixture.database.dbQueue,
                vaultId: fixture.vault.id,
                projectId: nil,
                initialName: "Retry"
            )
            let segment = TranscriptSegment(startTime: .now, text: "retained", isConfirmed: true)
            try installFailingInsertTrigger(in: fixture.database.dbQueue)

            do {
                try await service.persist(.finalized(segment))
                Issue.record("The forced insert failure should be reported")
            } catch {}

            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "DROP TRIGGER fail_transcript_insert")
            }
            let result = await service.stop()
            let persisted = try await fixture.database.dbQueue.read { db in
                try TranscriptSegmentRecord.fetchOne(db, key: segment.id)
            }

            #expect(result.succeeded)
            #expect(persisted?.text == "retained")
        }

        @Test
        func temporaryFailureRetriesWithoutWaitingForAnotherEvent() async throws {
            let fixture = try makePersistenceFixture()
            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: fixture.database.dbQueue,
                vaultId: fixture.vault.id,
                projectId: nil,
                initialName: "Automatic retry"
            )
            let segment = TranscriptSegment(startTime: .now, text: "automatic", isConfirmed: true)
            try installFailingInsertTrigger(in: fixture.database.dbQueue)

            do {
                try await service.persist(.finalized(segment))
                Issue.record("The forced insert failure should be reported")
            } catch {}
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "DROP TRIGGER fail_transcript_insert")
            }

            let automaticallyPersisted = await waitUntil {
                (try? fixture.database.dbQueue.read { db in
                    try TranscriptSegmentRecord.fetchOne(db, key: segment.id) != nil
                }) == true
            }

            #expect(automaticallyPersisted)
        }

        @Test
        func persistentFailureRetainsNewEventsForStop() async throws {
            let fixture = try makePersistenceFixture()
            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: fixture.database.dbQueue,
                vaultId: fixture.vault.id,
                projectId: nil,
                initialName: "Backoff"
            )
            let first = TranscriptSegment(startTime: .now, text: "first", isConfirmed: true)
            let second = TranscriptSegment(startTime: .now, text: "second", isConfirmed: true)
            try installFailingInsertTrigger(in: fixture.database.dbQueue)

            do {
                try await service.persist(.finalized(first))
                Issue.record("The initial forced failure should be reported")
            } catch {}
            do {
                try await service.persist(.finalized(second))
            } catch {}

            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "DROP TRIGGER fail_transcript_insert")
            }
            let result = await service.stop()
            let persistedIds = try await fixture.database.dbQueue.read { db in
                try UUID.fetchAll(
                    db,
                    sql: "SELECT id FROM transcript_segments WHERE meetingId = ?",
                    arguments: [service.meetingId]
                )
            }

            #expect(result.succeeded)
            #expect(Set(persistedIds) == Set([first.id, second.id]))
        }

        @Test
        func repeatedFlushFailureDoesNotCompleteTheRecordingSession() async throws {
            let fixture = try makePersistenceFixture()
            let service = try MeetingPersistenceService(
                store: TranscriptStore(),
                dbQueue: fixture.database.dbQueue,
                vaultId: fixture.vault.id,
                projectId: nil,
                initialName: "Still failing"
            )
            let segment = TranscriptSegment(startTime: .now, text: "pending", isConfirmed: true)
            try installFailingInsertTrigger(in: fixture.database.dbQueue)

            do {
                try await service.persist(.finalized(segment))
            } catch {}
            let result = await service.stop()
            let session = try await fixture.database.dbQueue.read { db in
                try RecordingSessionRecord.fetchOne(db, key: service.recordingSessionId)
            }

            #expect(!result.succeeded)
            #expect(session?.endedAt == nil)
            #expect(session?.duration == nil)
        }
    }

    private struct PersistenceFixture {
        let database: AppDatabaseManager
        let vault: VaultRecord
    }

    @MainActor
    private func makePersistenceFixture() throws -> PersistenceFixture {
        let database = try AppDatabaseManager(path: ":memory:")
        let vault = VaultRecord(
            id: .v7(),
            path: URL.temporaryDirectory.path,
            name: "Persistence Retry",
            createdAt: .now,
            lastOpenedAt: .now
        )
        try database.dbQueue.write { db in
            try vault.insert(db)
        }
        return PersistenceFixture(database: database, vault: vault)
    }

    private func installFailingInsertTrigger(in dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                CREATE TRIGGER fail_transcript_insert
                BEFORE INSERT ON transcript_segments
                BEGIN
                    SELECT RAISE(FAIL, 'forced transcript insert failure');
                END
                """
            )
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    if condition() { return true }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
#endif
