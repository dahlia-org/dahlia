#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct LiveCaptionEventRelayTests {
        @Test
        func blockedSinkKeepsOnlyLatestPreviewAndBoundsFinalizedBacklog() async throws {
            let recorder = LiveCaptionEventRecorder(blocksFirstDelivery: true)
            let relay = LiveCaptionEventRelay { events in
                await recorder.append(events)
            }
            let sessionID = UUID.v7()

            await relay.enqueue(.preview(makeSegment(
                sessionID: sessionID,
                text: "initial preview"
            )))
            await recorder.waitForDelivery()

            for index in 0 ..< 1_000 {
                await relay.enqueue(.preview(makeSegment(
                    sessionID: sessionID,
                    text: "preview \(index)"
                )))
            }
            #expect(await relay.pendingEventCount() == 1)

            for index in 0 ..< 150 {
                await relay.enqueue(.finalized(makeSegment(
                    sessionID: sessionID,
                    text: "final \(index)",
                    isConfirmed: true
                )))
            }
            #expect(await relay.pendingEventCount() == LiveCaptionEventRelay.maximumPendingEventCount)

            await recorder.open()
            await relay.finish()

            let deliveredEvents = await recorder.events()
            #expect(deliveredEvents.count == LiveCaptionEventRelay.maximumPendingEventCount + 1)
            guard case let .finalized(lastSegment) = try #require(deliveredEvents.last) else {
                Issue.record("Expected the latest finalized caption")
                return
            }
            #expect(lastSegment.text == "final 149")
        }

        private func makeSegment(
            sessionID: UUID,
            text: String,
            isConfirmed: Bool = false
        ) -> TranscriptSegment {
            TranscriptSegment(
                sessionId: sessionID,
                startTime: Date(timeIntervalSince1970: 1_776_384_000),
                text: text,
                isConfirmed: isConfirmed,
                speakerLabel: "system"
            )
        }
    }

    private actor LiveCaptionEventRecorder {
        private var deliveredEvents: [TranscriptionEvent] = []
        private var blocksFirstDelivery: Bool
        private var deliveryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        init(blocksFirstDelivery: Bool) {
            self.blocksFirstDelivery = blocksFirstDelivery
        }

        func append(_ events: [TranscriptionEvent]) async {
            deliveredEvents.append(contentsOf: events)
            let waiters = deliveryWaiters
            deliveryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if blocksFirstDelivery {
                await withCheckedContinuation { continuation in
                    releaseContinuation = continuation
                }
            }
        }

        func waitForDelivery() async {
            guard deliveredEvents.isEmpty else { return }
            await withCheckedContinuation { continuation in
                deliveryWaiters.append(continuation)
            }
        }

        func open() {
            blocksFirstDelivery = false
            releaseContinuation?.resume()
            releaseContinuation = nil
        }

        func events() -> [TranscriptionEvent] {
            deliveredEvents
        }
    }
#endif
