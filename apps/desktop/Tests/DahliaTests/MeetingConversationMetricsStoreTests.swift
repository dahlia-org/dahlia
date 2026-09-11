import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingConversationMetricsStoreTests {
        @Test
        func hidesUnsupportedTargetsAndShowsServerStates() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let meetingID = UUID.v7()
            let eligibility = EligibilitySequence([.hidden, .syncPending, .noTranscript])
            let store = MeetingConversationMetricsStore(
                eligibilityLoader: { _, _ in await eligibility.next() },
                metricsLoader: { _ in .recordingAudioMissing }
            )

            await store.prepare(meetingID: meetingID, dbQueue: database.dbQueue)
            #expect(!store.isTabAvailable)
            #expect(store.status == .hidden)

            await store.prepare(meetingID: meetingID, dbQueue: database.dbQueue)
            #expect(store.isTabAvailable)
            #expect(store.status == .syncPending)

            await store.prepare(meetingID: meetingID, dbQueue: database.dbQueue)
            #expect(store.isTabAvailable)
            #expect(store.status == .noTranscript)
        }

        @Test
        func displaysRecordingAudioUnavailable() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let target = Self.target(meetingID: .v7())
            let store = MeetingConversationMetricsStore(
                eligibilityLoader: { _, _ in .available(target) },
                metricsLoader: { _ in .recordingAudioMissing }
            )

            await store.prepare(meetingID: target.meetingID, dbQueue: database.dbQueue)
            await store.load()

            #expect(store.status == .recordingAudioMissing)
            #expect(store.metrics == nil)
        }

        @Test
        func invalidationPreservesTabUntilReplacementEligibilityPublishes() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let first = Self.target(meetingID: .v7(), transcriptVersion: 1)
            let second = Self.target(meetingID: first.meetingID, transcriptVersion: 2)
            let eligibility = EligibilitySequence([.available(first), .available(second)])
            let store = MeetingConversationMetricsStore(
                eligibilityLoader: { _, _ in await eligibility.next() },
                metricsLoader: { _ in .recordingAudioMissing }
            )

            await store.prepare(meetingID: first.meetingID, dbQueue: database.dbQueue)
            #expect(store.target == first)
            store.invalidate(meetingId: first.meetingID)
            #expect(store.isTabAvailable)
            #expect(store.status == .loading)
            #expect(store.target == nil)

            await store.prepare(meetingID: first.meetingID, dbQueue: database.dbQueue)
            #expect(store.isTabAvailable)
            #expect(store.status == .loading)
            #expect(store.target == second)
        }

        @Test
        func rejectsCompletionFromPreviousTranscriptVersion() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let loader = ControlledMetricsLoader()
            let first = Self.target(meetingID: .v7(), transcriptVersion: 1)
            let second = Self.target(meetingID: first.meetingID, transcriptVersion: 2)
            let eligibility = EligibilitySequence([.available(first), .available(second)])
            let store = MeetingConversationMetricsStore(
                eligibilityLoader: { _, _ in await eligibility.next() },
                metricsLoader: { try await loader.load($0) }
            )

            await store.prepare(meetingID: first.meetingID, dbQueue: database.dbQueue)
            let firstTask = Task { await store.load() }
            await loader.waitUntilRequested(first)

            await store.prepare(meetingID: second.meetingID, dbQueue: database.dbQueue)
            let secondTask = Task { await store.load() }
            await loader.waitUntilRequested(second)

            await loader.complete(second, with: .ready(Self.metrics(target: second)))
            await secondTask.value
            await loader.complete(first, with: .ready(Self.metrics(target: first)))
            await firstTask.value

            #expect(store.metrics?.transcriptVersion == 2)
            #expect(store.status == .ready)
        }

        private nonisolated static func target(
            meetingID: UUID,
            transcriptVersion: Int = 1
        ) -> ServerConversationAnalyticsService.Target {
            .init(
                meetingID: meetingID,
                transcriptID: .v7(),
                transcriptVersion: transcriptVersion,
                connectionID: .v7(),
                origin: URL.temporaryDirectory.appending(path: "analytics.invalid")
            )
        }

        private nonisolated static func metrics(
            target: ServerConversationAnalyticsService.Target
        ) -> MeetingConversationMetrics {
            MeetingConversationMetrics(
                transcriptID: target.transcriptID,
                transcriptVersion: target.transcriptVersion,
                calculationVersion: 1,
                recordingDuration: 10,
                unionSpeechDuration: 5,
                overlapDuration: 1,
                conversationOccupancyRatio: 0.5,
                overlapRatio: 0.2,
                sources: [],
                speechMergeGap: 1.5,
                monologueMergeGap: 3,
                longestMonologue: nil,
                paceSamples: [],
                paceBucketDuration: 60,
                timelineIntervals: [],
                overlapIntervals: [],
                overlapCount: 0,
                isTimelineCondensed: false
            )
        }
    }

    private actor EligibilitySequence {
        private var values: [ServerConversationAnalyticsService.Eligibility]

        init(_ values: [ServerConversationAnalyticsService.Eligibility]) {
            self.values = values
        }

        func next() -> ServerConversationAnalyticsService.Eligibility {
            values.removeFirst()
        }
    }

    private actor ControlledMetricsLoader {
        private var requests: Set<ServerConversationAnalyticsService.Target> = []
        private var requestWaiters: [ServerConversationAnalyticsService.Target: [CheckedContinuation<Void, Never>]] = [:]
        private var continuations: [ServerConversationAnalyticsService.Target: CheckedContinuation<
            ServerConversationAnalyticsService.Result,
            any Error
        >] = [:]

        func load(_ target: ServerConversationAnalyticsService.Target) async throws -> ServerConversationAnalyticsService.Result {
            requests.insert(target)
            requestWaiters.removeValue(forKey: target)?.forEach { $0.resume() }
            return try await withCheckedThrowingContinuation { continuation in
                continuations[target] = continuation
            }
        }

        func waitUntilRequested(_ target: ServerConversationAnalyticsService.Target) async {
            guard !requests.contains(target) else { return }
            await withCheckedContinuation { continuation in
                requestWaiters[target, default: []].append(continuation)
            }
        }

        func complete(
            _ target: ServerConversationAnalyticsService.Target,
            with result: ServerConversationAnalyticsService.Result
        ) {
            continuations.removeValue(forKey: target)?.resume(returning: result)
        }
    }
#endif
