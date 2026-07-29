import Foundation
import GRDB
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @Suite(.serialized)
    struct MeetingMetricsCoordinatorTests {
        @Test
        func revisionBurstAnalyzesOnlyNewestPendingValueAndRetainsNoInactiveDemand() async throws {
            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            let firstAnalysisGate = AsyncMetricsGate()
            let recorder = RevisionAnalysisRecorder(
                dbQueue: database.dbQueue,
                firstAnalysisGate: firstAnalysisGate
            )
            let coordinator = await MeetingMetricsCoordinator(
                dbQueue: database.dbQueue,
                analyze: { meetingId in try await recorder.analyze(meetingId: meetingId) }
            )
            await coordinator.activate(meetingId: meeting.id)
            #expect(await waitUntil { await recorder.revisions() == [0] })

            let mainActorGate = SynchronousMetricsGate()
            let mainActorBlocker = Task { @MainActor in mainActorGate.block() }
            #expect(await mainActorGate.waitUntilStarted())
            for _ in 0 ..< 3 {
                try await database.dbQueue.write { db in
                    try MeetingTranscriptRevision.bump(meetingId: meeting.id, in: db)
                }
            }
            mainActorGate.release()
            await mainActorBlocker.value

            #expect(await waitUntil { await recorder.revisions().count == 2 })
            #expect(await recorder.revisions() == [0, 3])
            await firstAnalysisGate.release()
            await coordinator.deactivate()

            let inactiveGate = SynchronousMetricsGate()
            let inactiveBlocker = Task { @MainActor in inactiveGate.block() }
            #expect(await inactiveGate.waitUntilStarted())
            for _ in 0 ..< 2 {
                try await database.dbQueue.write { db in
                    try MeetingTranscriptRevision.bump(meetingId: meeting.id, in: db)
                }
            }
            inactiveGate.release()
            await inactiveBlocker.value
            await drainMainActor()

            #expect(await recorder.revisions() == [0, 3])
            #expect(await coordinator.phase == .idle)
        }

        @Test
        func realtimeCommitRefreshesActiveMetrics() async throws {
            let (database, _, meeting, session) = try MeetingMetricsTestSupport.database()
            let recorder = RevisionAnalysisRecorder(dbQueue: database.dbQueue)
            let coordinator = await MeetingMetricsCoordinator(
                dbQueue: database.dbQueue,
                analyze: { meetingId in try await recorder.analyze(meetingId: meetingId) }
            )
            await coordinator.activate(meetingId: meeting.id)
            #expect(await waitUntil { await recorder.revisions() == [0] })

            let writer = TranscriptPersistenceWriter(
                dbQueue: database.dbQueue,
                meetingId: meeting.id,
                recordingSessionId: session.id,
                persistencePolicy: .streaming
            )
            try await writer.persist(.finalized(TranscriptSegment(
                startTime: MeetingMetricsTestSupport.baseDate,
                endTime: MeetingMetricsTestSupport.baseDate.addingTimeInterval(2),
                text: "realtime",
                isConfirmed: true,
                speakerLabel: "mic"
            )))

            #expect(await waitUntil { await recorder.revisions() == [0, 1] })
            await coordinator.deactivate()
        }

        @Test
        func delayedSameShapeBatchReplacementRefreshesActiveMetrics() async throws {
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
            try await database.dbQueue.write { db in try original.insert(db) }
            let recorder = RevisionAnalysisRecorder(dbQueue: database.dbQueue)
            let coordinator = await MeetingMetricsCoordinator(
                dbQueue: database.dbQueue,
                analyze: { meetingId in try await recorder.analyze(meetingId: meetingId) }
            )
            await coordinator.activate(meetingId: meeting.id)
            #expect(await waitUntil { await recorder.revisions() == [0] })

            let replacement = MeetingMetricsTestSupport.record(
                meetingId: meeting.id,
                sessionId: session.id,
                start: 3,
                end: 10,
                text: "replacement"
            )
            try BatchTranscriptionPersistence.complete(
                sessionId: session.id,
                meetingId: meeting.id,
                records: [replacement],
                completedAt: MeetingMetricsTestSupport.baseDate.addingTimeInterval(20),
                dbQueue: database.dbQueue
            )

            #expect(await waitUntil { await recorder.revisions() == [0, 1] })
            await coordinator.deactivate()
        }

        @Test
        func switchingMeetingsRejectsStaleCompletion() async throws {
            let (database, vault, firstMeeting, _) = try MeetingMetricsTestSupport.database()
            let secondMeeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: "Second",
                status: .ready,
                duration: nil,
                createdAt: MeetingMetricsTestSupport.baseDate,
                updatedAt: MeetingMetricsTestSupport.baseDate
            )
            try await database.dbQueue.write { db in try secondMeeting.insert(db) }
            let firstGate = AsyncMetricsGate()
            let staleResult = result(meetingId: firstMeeting.id, revision: 0, seconds: 111)
            let currentResult = result(meetingId: secondMeeting.id, revision: 0, seconds: 222)
            let coordinator = await MeetingMetricsCoordinator(
                dbQueue: database.dbQueue,
                analyze: { meetingId in
                    if meetingId == firstMeeting.id {
                        await firstGate.wait()
                        return .saved(staleResult, MeetingMetricsEvaluator.evaluate(staleResult))
                    }
                    return .saved(currentResult, MeetingMetricsEvaluator.evaluate(currentResult))
                }
            )

            await coordinator.activate(meetingId: firstMeeting.id)
            await coordinator.activate(meetingId: secondMeeting.id)
            #expect(await waitUntil { await coordinator.result?.meetingId == secondMeeting.id })
            await firstGate.release()
            await drainMainActor()

            #expect(await coordinator.result?.meetingId == secondMeeting.id)
            #expect(await coordinator.result?.conversationTalkSeconds == 222)
            await coordinator.deactivate()
        }

        @Test
        func deactivateCancelsObservationAndAnalysis() async throws {
            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            let probe = CancellationProbe()
            let coordinator = await MeetingMetricsCoordinator(
                dbQueue: database.dbQueue,
                analyze: { _ in try await probe.waitForCancellation() }
            )
            await coordinator.activate(meetingId: meeting.id)
            #expect(await probe.waitUntilStarted())

            await coordinator.deactivate()
            #expect(await probe.waitUntilCancelled())
            try await database.dbQueue.write { db in
                try MeetingTranscriptRevision.bump(meetingId: meeting.id, in: db)
            }
            await drainMainActor()

            #expect(await probe.startCount() == 1)
            #expect(await coordinator.phase == .idle)
        }

        @Test
        func databaseConsumptionDoesNotBlockMainActor() async throws {
            let (database, _, meeting, session) = try MeetingMetricsTestSupport.database()
            try insertLongTranscript(meetingId: meeting.id, sessionId: session.id, database: database)
            let readGate = SynchronousMetricsGate()
            let worker = MeetingMetricsWorker(
                dbQueue: database.dbQueue,
                rowReadHook: { row in
                    if row == MeetingMetricsConstants.cancellationCheckSegmentStride {
                        readGate.block()
                    }
                }
            )
            let coordinator = await MeetingMetricsCoordinator(dbQueue: database.dbQueue, worker: worker)
            await coordinator.activate(meetingId: meeting.id)
            #expect(await readGate.waitUntilStarted())

            let marker = MainActorMarker()
            await marker.mark()
            #expect(await marker.isMarked())

            readGate.release()
            await coordinator.deactivate()
        }

        @Test
        func compareAndSwapRejectionReschedulesExactlyOnce() async throws {
            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            let probe = OutcomeSequenceProbe(outcomes: [
                .revisionChanged(1),
                .empty(revision: 1),
            ])
            let coordinator = await MeetingMetricsCoordinator(
                dbQueue: database.dbQueue,
                analyze: { _ in await probe.next() }
            )
            await coordinator.activate(meetingId: meeting.id)

            #expect(await waitUntil { await probe.callCount() == 2 })
            #expect(await coordinator.phase == .empty)
            #expect(await probe.callCount() == 2)
            await coordinator.deactivate()
        }

        @Test
        func cancellationDuringCursorReadReleasesDatabaseWithoutStaleSaveOrPublication() async throws {
            let (database, _, meeting, session) = try MeetingMetricsTestSupport.database()
            try insertLongTranscript(meetingId: meeting.id, sessionId: session.id, database: database)
            let readGate = SynchronousMetricsGate()
            let worker = MeetingMetricsWorker(
                dbQueue: database.dbQueue,
                rowReadHook: { row in
                    if row == MeetingMetricsConstants.cancellationCheckSegmentStride {
                        readGate.block()
                    }
                }
            )
            let coordinator = await MeetingMetricsCoordinator(dbQueue: database.dbQueue, worker: worker)
            await coordinator.activate(meetingId: meeting.id)
            #expect(await readGate.waitUntilStarted())

            await coordinator.deactivate()
            readGate.release()
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE meetings SET name = ? WHERE id = ?",
                    arguments: ["read released", meeting.id]
                )
            }
            let persisted = try await database.dbQueue.read { db in
                try (
                    String.fetchOne(db, sql: "SELECT name FROM meetings WHERE id = ?", arguments: [meeting.id]),
                    MeetingMetricsRecord.filter(Column("meetingId") == meeting.id).fetchCount(db),
                    MeetingSourceMetricsRecord.filter(Column("meetingId") == meeting.id).fetchCount(db)
                )
            }

            #expect(persisted.0 == "read released")
            #expect(persisted.1 == 0)
            #expect(persisted.2 == 0)
            #expect(await coordinator.phase == .idle)
            #expect(await coordinator.result == nil)
            #expect(await coordinator.insights == nil)
        }

        private func insertLongTranscript(
            meetingId: UUID,
            sessionId: UUID,
            database: AppDatabaseManager
        ) throws {
            try database.dbQueue.write { db in
                for index in 0 ..< 1_100 {
                    let start = Double(index) * 1.1
                    try MeetingMetricsTestSupport.record(
                        meetingId: meetingId,
                        sessionId: sessionId,
                        start: start,
                        end: start + 1,
                        text: "発話\(index)",
                        speakerLabel: index.isMultiple(of: 2) ? "mic" : "system"
                    ).insert(db)
                }
            }
        }

        private func result(
            meetingId: UUID,
            revision: Int64,
            seconds: Double
        ) -> MeetingMetricsResult {
            MeetingMetricsResult(
                meetingId: meetingId,
                metricsVersion: MeetingMetricsConstants.metricsVersion,
                transcriptRevision: revision,
                conversationTalkSeconds: seconds,
                overlapSeconds: nil,
                talkBalance: nil,
                confirmedSegmentCount: 1,
                validSegmentCount: 1,
                invalidDurationSegmentCount: 0,
                unknownSourceSegmentCount: 0,
                totalCharacterCount: 2,
                validCharacterCount: 2,
                unknownSourceCharacterCount: 0,
                sourceRows: []
            )
        }

        private func waitUntil(
            timeout: Duration = .seconds(10),
            condition: @escaping @Sendable () async -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if await condition() { return true }
                await Task.yield()
            }
            return false
        }

        private func drainMainActor() async {
            for _ in 0 ..< 20 {
                await Task.yield()
                await MainActor.run {}
            }
        }
    }

    private actor RevisionAnalysisRecorder {
        private let dbQueue: DatabaseQueue
        private let firstAnalysisGate: AsyncMetricsGate?
        private var recordedRevisions: [Int64] = []

        init(dbQueue: DatabaseQueue, firstAnalysisGate: AsyncMetricsGate? = nil) {
            self.dbQueue = dbQueue
            self.firstAnalysisGate = firstAnalysisGate
        }

        func analyze(meetingId: UUID) async throws -> MeetingMetricsWorker.Outcome {
            let revision = try await dbQueue.read { db in
                try MeetingTranscriptRevision.current(meetingId: meetingId, in: db)
            }
            recordedRevisions.append(revision)
            if recordedRevisions.count == 1, let firstAnalysisGate {
                await firstAnalysisGate.wait()
            }
            try Task.checkCancellation()
            return .empty(revision: revision)
        }

        func revisions() -> [Int64] {
            recordedRevisions
        }
    }

    private actor AsyncMetricsGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func release() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
        }
    }

    private final class SynchronousMetricsGate: Sendable {
        private let hasStarted = OSAllocatedUnfairLock(initialState: false)
        private let releaseSemaphore = DispatchSemaphore(value: 0)

        func block() {
            hasStarted.withLock { $0 = true }
            releaseSemaphore.wait()
        }

        func release() {
            releaseSemaphore.signal()
        }

        func waitUntilStarted() async -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if hasStarted.withLock(\.self) { return true }
                await Task.yield()
            }
            return false
        }
    }

    private actor CancellationProbe {
        private var started = 0
        private var cancelled = false

        func waitForCancellation() async throws -> MeetingMetricsWorker.Outcome {
            started += 1
            do {
                while true {
                    try await Task.sleep(for: .seconds(60))
                }
            } catch is CancellationError {
                cancelled = true
                throw CancellationError()
            }
        }

        func waitUntilStarted() async -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if started > 0 { return true }
                await Task.yield()
            }
            return false
        }

        func waitUntilCancelled() async -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if cancelled { return true }
                await Task.yield()
            }
            return false
        }

        func startCount() -> Int {
            started
        }
    }

    private actor OutcomeSequenceProbe {
        private var outcomes: [MeetingMetricsWorker.Outcome]
        private var calls = 0

        init(outcomes: [MeetingMetricsWorker.Outcome]) {
            self.outcomes = outcomes
        }

        func next() -> MeetingMetricsWorker.Outcome {
            calls += 1
            return outcomes.removeFirst()
        }

        func callCount() -> Int {
            calls
        }
    }

    @MainActor
    private final class MainActorMarker {
        private var marked = false

        func mark() {
            marked = true
        }

        func isMarked() -> Bool {
            marked
        }
    }
#endif
