import Foundation
import GRDB
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @Suite(.serialized)
    struct MeetingMetricsReworkTests {
        @Test
        func continuouslyAdvancingCompareAndSwapWaitsForSettleBetweenAnalyses() async throws {
            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            let probe = RevisionSettleOrderingProbe()
            let coordinator = await MeetingMetricsCoordinator(
                dbQueue: database.dbQueue,
                analyze: { _ in await probe.analyze() },
                waitForRevisionSettle: { await probe.waitForSettle() }
            )
            await coordinator.activate(meetingId: meeting.id)
            try #require(await probe.nextEvent() == .settle(1))

            for expectedCallCount in 2 ... 4 {
                await probe.releaseNextSettle()
                #expect(await probe.nextEvent() == .analysis(expectedCallCount))
                #expect(await probe.nextEvent() == .settle(expectedCallCount))
            }

            #expect(await probe.callCount() == 4)
            #expect(await coordinator.phase == .waitingForStableRevision)
            await coordinator.deactivate()
            await probe.releaseNextSettle()
        }

        @Test
        func observationFailureThenRetryRestartsRevisionRefresh() async throws {
            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            let observationProbe = ObservationFailureProbe()
            let recorder = RevisionAnalysisRecorder(dbQueue: database.dbQueue)
            let coordinator = await MeetingMetricsCoordinator(
                dbQueue: database.dbQueue,
                analyze: { meetingId in try await recorder.analyze(meetingId: meetingId) },
                observeRevisions: { _ in await observationProbe.nextStream() },
                waitForRevisionSettle: {}
            )
            await coordinator.activate(meetingId: meeting.id)
            #expect(await waitUntil { await coordinator.phase == .failed })

            await coordinator.retry()
            #expect(await waitUntil { await recorder.revisions().contains(0) })
            try await database.dbQueue.write { db in
                try MeetingTranscriptRevision.bump(meetingId: meeting.id, in: db)
            }
            await observationProbe.yield(1)

            #expect(await waitUntil { await recorder.revisions().last == 1 })
            await coordinator.deactivate()
            await observationProbe.finish()
        }

        @Test
        func failedPhaseHidesStaleBreakdownResult() async {
            let stale = result(meetingId: .v7(), revision: 1, seconds: 42)
            let displayed = await MeetingMetricsTabView.breakdownResult(phase: .failed, result: stale)

            #expect(displayed == nil)
            #expect(await MeetingMetricsTabView.breakdownResult(phase: .ready, result: stale) == stale)
        }

        @Test
        func workerUsesRevisionMatchedCacheWithoutReadingTranscriptRows() async throws {
            let (database, _, meeting, session) = try MeetingMetricsTestSupport.database()
            try await database.dbQueue.write { db in
                try MeetingMetricsTestSupport.record(
                    meetingId: meeting.id,
                    sessionId: session.id,
                    start: 0,
                    end: 120,
                    text: "cached"
                ).insert(db)
            }
            let firstWorker = MeetingMetricsWorker(dbQueue: database.dbQueue)
            let first = try await firstWorker.analyze(meetingId: meeting.id)
            let rowReads = OSAllocatedUnfairLock(initialState: 0)
            let cachedWorker = MeetingMetricsWorker(
                dbQueue: database.dbQueue,
                rowReadHook: { _ in rowReads.withLock { $0 += 1 } }
            )
            let cached = try await cachedWorker.analyze(meetingId: meeting.id)

            #expect(first == cached)
            #expect(rowReads.withLock(\.self) == 0)
        }

        @Test
        func workerReleasesDatabaseBeforeFoldingRows() async throws {
            let (database, _, meeting, session) = try MeetingMetricsTestSupport.database()
            try await database.dbQueue.write { db in
                try MeetingMetricsTestSupport.record(
                    meetingId: meeting.id,
                    sessionId: session.id,
                    start: 0,
                    end: 120,
                    text: "fold"
                ).insert(db)
            }
            let foldGate = SynchronousMetricsGate()
            let worker = MeetingMetricsWorker(
                dbQueue: database.dbQueue,
                rowReadHook: { row in
                    if row == 1 { foldGate.block() }
                }
            )
            let analysis = Task { try await worker.analyze(meetingId: meeting.id) }
            #expect(await foldGate.waitUntilStarted())

            let writeFinished = OSAllocatedUnfairLock(initialState: false)
            let write = Task {
                try await database.dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE meetings SET name = ? WHERE id = ?",
                        arguments: ["queue released", meeting.id]
                    )
                }
                writeFinished.withLock { $0 = true }
            }
            #expect(await waitUntil { writeFinished.withLock(\.self) })

            foldGate.release()
            _ = try await analysis.value
            try await write.value
        }

        @Test
        func workerBoundsLongTranscriptAndCachePreservesPartialState() async throws {
            let (database, _, meeting, session) = try MeetingMetricsTestSupport.database()
            try await database.dbQueue.write { db in
                for index in 0 ... MeetingMetricsConstants.maximumAnalyzedSegmentCount {
                    let start = Double(index)
                    try MeetingMetricsTestSupport.record(
                        meetingId: meeting.id,
                        sessionId: session.id,
                        start: start,
                        end: start + 1,
                        text: "a"
                    ).insert(db)
                }
            }
            let worker = MeetingMetricsWorker(dbQueue: database.dbQueue)
            let outcome = try await worker.analyze(meetingId: meeting.id)
            guard case let .saved(result, _) = outcome else {
                Issue.record("Expected bounded metrics result")
                return
            }

            #expect(result.isPartialAnalysis)
            #expect(result.confirmedSegmentCount == MeetingMetricsConstants.maximumAnalyzedSegmentCount)
            let cached = try #require(await MeetingMetricsPersistence.load(meetingId: meeting.id, dbQueue: database.dbQueue))
            #expect(cached.isPartialAnalysis)
        }

        @Test
        func workerExcludesUnconfirmedSegmentsFromMetricsAndCoverage() async throws {
            let (database, _, meeting, session) = try MeetingMetricsTestSupport.database()
            try await database.dbQueue.write { db in
                try MeetingMetricsTestSupport.record(
                    meetingId: meeting.id,
                    sessionId: session.id,
                    start: 0,
                    end: 10,
                    text: "abc",
                    speakerLabel: "mic"
                ).insert(db)
                try MeetingMetricsTestSupport.record(
                    meetingId: meeting.id,
                    sessionId: session.id,
                    start: 2,
                    end: 12,
                    text: "unconfirmed system",
                    confirmed: false,
                    speakerLabel: "system"
                ).insert(db)
                try MeetingMetricsTestSupport.record(
                    meetingId: meeting.id,
                    sessionId: session.id,
                    start: 12,
                    end: 14,
                    text: "unconfirmed unknown",
                    confirmed: false,
                    speakerLabel: nil
                ).insert(db)
                try MeetingMetricsTestSupport.record(
                    meetingId: meeting.id,
                    sessionId: session.id,
                    start: 14,
                    end: nil,
                    text: "unconfirmed invalid",
                    confirmed: false,
                    speakerLabel: "mic"
                ).insert(db)
            }

            let worker = MeetingMetricsWorker(dbQueue: database.dbQueue)
            guard case let .saved(result, _) = try await worker.analyze(meetingId: meeting.id) else {
                Issue.record("Expected metrics for the confirmed segment")
                return
            }

            #expect(result.conversationTalkSeconds == 10)
            #expect(result.overlapSeconds == nil)
            #expect(result.confirmedSegmentCount == 1)
            #expect(result.validSegmentCount == 1)
            #expect(result.invalidDurationSegmentCount == 0)
            #expect(result.unknownSourceSegmentCount == 0)
            #expect(result.totalCharacterCount == 3)
            #expect(result.validCharacterCount == 3)
            #expect(result.unknownSourceCharacterCount == 0)
            #expect(result.sourceRows.count == 1)
            let microphone = try #require(result.sourceRows.first)
            #expect(microphone.source == .microphone)
            #expect(microphone.speakingSeconds == 10)
            #expect(microphone.characterCount == 3)
            #expect(microphone.turnCount == 1)
        }

        private func result(meetingId: UUID, revision: Int64, seconds: Double) -> MeetingMetricsResult {
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
                sourceRows: [],
                isPartialAnalysis: false
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

    }

    private actor RevisionAnalysisRecorder {
        private let dbQueue: DatabaseQueue
        private var recordedRevisions: [Int64] = []

        init(dbQueue: DatabaseQueue) {
            self.dbQueue = dbQueue
        }

        func analyze(meetingId: UUID) async throws -> MeetingMetricsWorker.Outcome {
            let revision = try await dbQueue.read { db in
                try MeetingTranscriptRevision.current(meetingId: meetingId, in: db)
            }
            recordedRevisions.append(revision)
            return .empty(revision: revision)
        }

        func revisions() -> [Int64] {
            recordedRevisions
        }
    }

    private actor RevisionSettleOrderingProbe {
        enum Event: Equatable {
            case analysis(Int)
            case settle(Int)
        }

        private var calls = 0
        private var waits = 0
        private var events: [Event] = []
        private var eventWaiters: [CheckedContinuation<Event, Never>] = []
        private var settleWaiters: [CheckedContinuation<Void, Never>] = []

        func analyze() -> MeetingMetricsWorker.Outcome {
            calls += 1
            if calls > 1 {
                publish(.analysis(calls))
            }
            return .revisionChanged(Int64(calls))
        }

        func waitForSettle() async {
            waits += 1
            publish(.settle(waits))
            await withCheckedContinuation { continuation in
                settleWaiters.append(continuation)
            }
        }

        func nextEvent() async -> Event {
            if !events.isEmpty {
                return events.removeFirst()
            }
            return await withCheckedContinuation { continuation in
                eventWaiters.append(continuation)
            }
        }

        func releaseNextSettle() {
            guard !settleWaiters.isEmpty else { return }
            settleWaiters.removeFirst().resume()
        }

        func callCount() -> Int {
            calls
        }

        private func publish(_ event: Event) {
            if eventWaiters.isEmpty {
                events.append(event)
            } else {
                eventWaiters.removeFirst().resume(returning: event)
            }
        }
    }

    private actor ObservationFailureProbe {
        private var streamCount = 0
        private var continuation: AsyncThrowingStream<Int64, Error>.Continuation?

        func nextStream() -> AsyncThrowingStream<Int64, Error> {
            streamCount += 1
            let pair = AsyncThrowingStream<Int64, Error>.makeStream()
            pair.continuation.yield(0)
            if streamCount == 1 {
                pair.continuation.finish(throwing: ObservationProbeError.failed)
            } else {
                continuation = pair.continuation
            }
            return pair.stream
        }

        func yield(_ revision: Int64) {
            continuation?.yield(revision)
        }

        func finish() {
            continuation?.finish()
            continuation = nil
        }
    }

    private enum ObservationProbeError: Error {
        case failed
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
#endif
