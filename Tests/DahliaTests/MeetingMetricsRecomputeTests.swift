import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @Suite(.serialized)
    struct MeetingMetricsRecomputeTests {
        @Test
        func forcedRecomputeKeepsReadyPhaseAndSetsAndClearsIndicator() async throws {
            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            let initial = result(meetingId: meeting.id, revision: 0, seconds: 10)
            let updated = result(meetingId: meeting.id, revision: 0, seconds: 20)
            let probe = RecomputeAnalysisProbe(initial: initial, forced: updated)
            let coordinator = await MeetingMetricsCoordinator(
                dbQueue: database.dbQueue,
                analyze: { _, ignoringCache in try await probe.analyze(ignoringCache: ignoringCache) }
            )
            await coordinator.activate(meetingId: meeting.id)
            #expect(await waitUntil { await coordinator.phase == .ready })

            await coordinator.recompute()

            #expect(await probe.waitUntilForcedStarted())
            #expect(await coordinator.phase == .ready)
            #expect(await coordinator.isRecomputing)
            #expect(await coordinator.result == initial)

            await coordinator.recompute()
            #expect(await !probe.waitForCallCount(3, timeout: .milliseconds(100)))
            #expect(await probe.callModes() == [false, true])

            await probe.releaseForced()
            #expect(await waitUntil { await coordinator.result == updated })
            #expect(await coordinator.phase == .ready)
            #expect(await !coordinator.isRecomputing)
            await coordinator.deactivate()
        }

        @Test
        func deactivateDuringRecomputeClearsIndicator() async throws {
            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            let initial = result(meetingId: meeting.id, revision: 0, seconds: 10)
            let probe = RecomputeAnalysisProbe(initial: initial, forced: initial)
            let coordinator = await MeetingMetricsCoordinator(
                dbQueue: database.dbQueue,
                analyze: { _, ignoringCache in try await probe.analyze(ignoringCache: ignoringCache) }
            )
            await coordinator.activate(meetingId: meeting.id)
            #expect(await waitUntil { await coordinator.phase == .ready })
            await coordinator.recompute()
            #expect(await probe.waitUntilForcedStarted())
            #expect(await coordinator.isRecomputing)

            await coordinator.deactivate()

            #expect(await coordinator.phase == .idle)
            #expect(await !coordinator.isRecomputing)
            await probe.releaseForced()
        }

        @Test
        func recomputeRejectsStaleForcedResultAfterNewGeneration() async throws {
            let (database, _, meeting, _) = try MeetingMetricsTestSupport.database()
            let initial = result(meetingId: meeting.id, revision: 0, seconds: 10)
            let stale = result(meetingId: meeting.id, revision: 0, seconds: 20)
            let fresh = result(meetingId: meeting.id, revision: 0, seconds: 30)
            let probe = RecomputeAnalysisProbe(initial: initial, forced: stale, subsequent: fresh)
            let coordinator = await MeetingMetricsCoordinator(
                dbQueue: database.dbQueue,
                analyze: { _, ignoringCache in try await probe.analyze(ignoringCache: ignoringCache) }
            )
            await coordinator.activate(meetingId: meeting.id)
            #expect(await waitUntil { await coordinator.result == initial })
            let initialGeneration = await coordinator.analysisGeneration
            await coordinator.recompute()
            #expect(await probe.waitUntilForcedStarted())
            let recomputeGeneration = await coordinator.analysisGeneration
            #expect(recomputeGeneration > initialGeneration)

            await coordinator.retry()

            #expect(await waitUntil { await coordinator.result == fresh })
            #expect(await coordinator.analysisGeneration > recomputeGeneration)
            #expect(await probe.callModes() == [false, true, false])
            await probe.releaseForced()
            await Task.yield()
            #expect(await coordinator.result == fresh)
            await coordinator.deactivate()
        }

        @Test
        func recomputeControlIsDisabledWhileRecordingOrRecomputing() async {
            #expect(await MeetingMetricsTabView.isRecomputeDisabled(isListening: true, isRecomputing: false))
            #expect(await MeetingMetricsTabView.isRecomputeDisabled(isListening: false, isRecomputing: true))
            #expect(await !MeetingMetricsTabView.isRecomputeDisabled(isListening: false, isRecomputing: false))
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

    private actor RecomputeAnalysisProbe {
        private let initial: MeetingMetricsResult
        private let forced: MeetingMetricsResult
        private let subsequent: MeetingMetricsResult?
        private var modes: [Bool] = []
        private var forcedStarted = false
        private var forcedReleased = false
        private var forcedWaiters: [CheckedContinuation<Void, Never>] = []

        init(
            initial: MeetingMetricsResult,
            forced: MeetingMetricsResult,
            subsequent: MeetingMetricsResult? = nil
        ) {
            self.initial = initial
            self.forced = forced
            self.subsequent = subsequent
        }

        func analyze(ignoringCache: Bool) async throws -> MeetingMetricsWorker.Outcome {
            modes.append(ignoringCache)
            if ignoringCache {
                forcedStarted = true
                if !forcedReleased {
                    await withCheckedContinuation { continuation in
                        forcedWaiters.append(continuation)
                    }
                }
                return .saved(forced, MeetingMetricsEvaluator.evaluate(forced))
            }
            let result = modes.count == 1 ? initial : subsequent ?? initial
            return .saved(result, MeetingMetricsEvaluator.evaluate(result))
        }

        func waitUntilForcedStarted() async -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if forcedStarted { return true }
                await Task.yield()
            }
            return false
        }

        func releaseForced() {
            forcedReleased = true
            let waiters = forcedWaiters
            forcedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func callModes() -> [Bool] {
            modes
        }

        func waitForCallCount(_ count: Int, timeout: Duration = .seconds(10)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if modes.count >= count { return true }
                await Task.yield()
            }
            return false
        }
    }
#endif
