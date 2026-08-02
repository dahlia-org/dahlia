import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingConversationMetricsStoreTests {
        @Test
        func rejectsCompletionFromPreviouslySelectedMeeting() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let loader = ControlledMetricsLoader()
            let store = MeetingConversationMetricsStore { meetingId, _ in
                try await loader.load(meetingId: meetingId)
            }
            let firstMeetingId = UUID()
            let secondMeetingId = UUID()
            store.reset(for: firstMeetingId)

            let firstTask = Task {
                await store.load(meetingId: firstMeetingId, dbQueue: database.dbQueue)
            }
            await loader.waitUntilRequested(meetingId: firstMeetingId)
            store.reset(for: secondMeetingId)
            let secondTask = Task {
                await store.load(meetingId: secondMeetingId, dbQueue: database.dbQueue)
            }
            await loader.waitUntilRequested(meetingId: secondMeetingId)

            await loader.complete(meetingId: secondMeetingId, with: Self.metrics(fingerprint: "second"))
            await secondTask.value
            await loader.complete(meetingId: firstMeetingId, with: Self.metrics(fingerprint: "first"))
            await firstTask.value

            #expect(store.metrics?.inputFingerprint == "second")
            #expect(!store.isLoading)
        }

        @Test
        func retryClearsPreviousErrorAndLoadsMetrics() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let attempts = AttemptCounter()
            let store = MeetingConversationMetricsStore { _, _ in
                if await attempts.next() == 1 {
                    throw CocoaError(.fileReadUnknown)
                }
                return Self.metrics(fingerprint: "recovered")
            }
            let meetingId = UUID()

            await store.load(meetingId: meetingId, dbQueue: database.dbQueue)
            #expect(store.errorMessage != nil)

            await store.load(meetingId: meetingId, dbQueue: database.dbQueue)
            #expect(store.errorMessage == nil)
            #expect(store.metrics?.inputFingerprint == "recovered")
        }

        private nonisolated static func metrics(fingerprint: String) -> MeetingConversationMetrics {
            MeetingConversationMetrics(
                inputFingerprint: fingerprint,
                recordingDuration: 10,
                unionSpeechDuration: 5,
                overlapDuration: 1,
                usesLegacyTimelineFallback: false,
                computedAt: .now,
                sources: [],
                speechMergeGap: 1.5,
                monologueMergeGap: 3,
                longestMonologue: nil,
                paceSamples: [],
                paceBucketDuration: 60,
                timelineIntervals: [],
                overlapIntervals: [],
                overlapCount: 0,
                isTimelineCondensed: false,
                voiceAnalytics: .empty
            )
        }
    }

    private actor AttemptCounter {
        private var count = 0

        func next() -> Int {
            count += 1
            return count
        }
    }

    private actor ControlledMetricsLoader {
        private var requests: Set<UUID> = []
        private var requestWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
        private var continuations: [UUID: CheckedContinuation<MeetingConversationMetrics, any Error>] = [:]

        func load(meetingId: UUID) async throws -> MeetingConversationMetrics {
            requests.insert(meetingId)
            requestWaiters.removeValue(forKey: meetingId)?.forEach { $0.resume() }
            return try await withCheckedThrowingContinuation { continuation in
                continuations[meetingId] = continuation
            }
        }

        func waitUntilRequested(meetingId: UUID) async {
            guard !requests.contains(meetingId) else { return }
            await withCheckedContinuation { continuation in
                requestWaiters[meetingId, default: []].append(continuation)
            }
        }

        func complete(meetingId: UUID, with metrics: MeetingConversationMetrics) {
            continuations.removeValue(forKey: meetingId)?.resume(returning: metrics)
        }
    }
#endif
