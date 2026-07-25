#if canImport(Testing)
    import Foundation
    import GRDB
    import os
    import Testing
    @testable import Dahlia

    @MainActor
    @Suite(.timeLimit(.minutes(1)))
    struct TranscriptPersistenceRetryTests {
        @Test
        func stopRetriesEventsRetainedAfterATemporaryDatabaseFailure() async throws {
            let fixture = try makePersistenceFixture()
            let service = try await MeetingPersistenceService.createNew(
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
            let failedMetrics = await service.persistenceMetricsSnapshot()
            #expect(failedMetrics.pendingEventCount == 1)
            #expect(failedMetrics.pendingTextByteCount == segment.text.utf8.count)
            #expect(failedMetrics.oldestPendingEventAge != nil)
            #expect(failedMetrics.highWaterEventCount == 1)
            #expect(failedMetrics.highWaterTextByteCount == segment.text.utf8.count)
            #expect(failedMetrics.failedWriteAttemptCount >= 1)
            #expect(failedMetrics.currentRetryBackoff != nil)

            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "DROP TRIGGER fail_transcript_insert")
            }
            let result = await service.stop()
            let persisted = try await fixture.database.dbQueue.read { db in
                try TranscriptSegmentRecord.fetchOne(db, key: segment.id)
            }

            #expect(result.succeeded)
            #expect(persisted?.text == "retained")
            let drainedMetrics = await service.persistenceMetricsSnapshot()
            #expect(drainedMetrics.pendingEventCount == 0)
            #expect(drainedMetrics.pendingTextByteCount == 0)
            #expect(drainedMetrics.oldestPendingEventAge == nil)
            #expect(drainedMetrics.currentRetryBackoff == nil)
        }

        @Test
        func concurrentFlushesShareTheInFlightDatabaseWrite() async throws {
            let fixture = try makePersistenceFixture()
            let service = try await MeetingPersistenceService.createNew(
                store: TranscriptStore(),
                dbQueue: fixture.database.dbQueue,
                vaultId: fixture.vault.id,
                projectId: nil,
                initialName: "Single flight"
            )
            let databaseGate = PersistenceDatabaseGate()
            let databaseBlocker = Task {
                try await fixture.database.dbQueue.write { _ in
                    databaseGate.block()
                }
            }
            #expect(await databaseGate.waitUntilStarted())
            defer { databaseGate.release() }

            let segment = TranscriptSegment(startTime: .now, text: "once", isConfirmed: true)
            let persistTask = Task {
                try await service.persist(.finalized(segment))
            }
            #expect(await waitUntil {
                await service.persistenceMetricsSnapshot().isWriteInProgress
            })

            let flushTask = Task {
                try await service.flushPendingTranscriptEvents()
            }
            #expect(await waitUntil {
                await service.persistenceMetricsSnapshot().waitingFlushCount == 1
            })

            databaseGate.release()
            try await persistTask.value
            try await flushTask.value
            try await databaseBlocker.value

            let persistedCount = try await fixture.database.dbQueue.read { db in
                try TranscriptSegmentRecord
                    .filter(Column("id") == segment.id)
                    .fetchCount(db)
            }
            let metrics = await service.persistenceMetricsSnapshot()
            #expect(persistedCount == 1)
            #expect(metrics.pendingEventCount == 0)
            #expect(!metrics.isWriteInProgress)
            #expect(metrics.waitingFlushCount == 0)
            #expect(metrics.failedWriteAttemptCount == 0)
        }

        @Test
        func temporaryFailureRetriesWithoutWaitingForAnotherEvent() async throws {
            let fixture = try makePersistenceFixture()
            let service = try await MeetingPersistenceService.createNew(
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

            await waitUntil {
                (try? fixture.database.dbQueue.read { db in
                    try TranscriptSegmentRecord.fetchOne(db, key: segment.id) != nil
                }) == true
            }
            let automaticallyPersisted = try await fixture.database.dbQueue.read { db in
                try TranscriptSegmentRecord.fetchOne(db, key: segment.id) != nil
            }

            #expect(automaticallyPersisted)
        }

        @Test
        func persistentFailureRetainsNewEventsForStop() async throws {
            let fixture = try makePersistenceFixture()
            let service = try await MeetingPersistenceService.createNew(
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
            let service = try await MeetingPersistenceService.createNew(
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
        condition: @escaping @Sendable () -> Bool
    ) async {
        while !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private final class PersistenceDatabaseGate: @unchecked Sendable {
        private let hasStarted = OSAllocatedUnfairLock(initialState: false)
        private let releaseSemaphore = DispatchSemaphore(value: 0)

        func block() {
            hasStarted.withLock { $0 = true }
            _ = releaseSemaphore.wait(timeout: .now() + 10)
        }

        func release() {
            releaseSemaphore.signal()
        }

        func waitUntilStarted() async -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if hasStarted.withLock(\.self) {
                    return true
                }
                await Task.yield()
            }
            return false
        }
    }
#endif
