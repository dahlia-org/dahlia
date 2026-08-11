import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct FinalizedLiveTranscriptRelayTests {
        @Test
        func relayPreservesOrderWhileCoalescingABlockedBacklog() async {
            let recorder = LiveTranscriptDeliveryRecorder(blocksFirstDelivery: true)
            let relay = FinalizedLiveTranscriptRelay { delivery in
                await recorder.append(delivery)
            }
            let sessionID = UUID.v7()
            let expectedTexts = (0 ..< 1_000).map { "final-\($0)" }

            await relay.enqueue(sessionID: sessionID, text: expectedTexts[0])
            await recorder.waitForCount(1)
            for text in expectedTexts.dropFirst() {
                await relay.enqueue(sessionID: sessionID, text: text)
            }

            await recorder.open()
            await relay.finish()

            let deliveries = await recorder.snapshot()
            #expect(deliveries.map(\.sessionID).allSatisfy { $0 == sessionID })
            #expect(deliveries.map(\.text).joined(separator: "\n") == expectedTexts.joined(separator: "\n"))
            #expect(deliveries.allSatisfy { !$0.wasTruncated })
        }

        @Test
        func relayBoundsBacklogAndReportsTruncation() async {
            let recorder = LiveTranscriptDeliveryRecorder(blocksFirstDelivery: true)
            let relay = FinalizedLiveTranscriptRelay { delivery in
                await recorder.append(delivery)
            }
            let sessionID = UUID.v7()

            await relay.enqueue(sessionID: sessionID, text: "initial")
            await recorder.waitForCount(1)
            await relay.enqueue(
                sessionID: sessionID,
                text: String(repeating: "x", count: FinalizedLiveTranscriptRelay.maximumPendingCharacters + 10)
            )

            await recorder.open()
            await relay.finish()

            let deliveries = await recorder.snapshot()
            #expect(deliveries.count == 2)
            #expect(deliveries[1].text.count == FinalizedLiveTranscriptRelay.maximumPendingCharacters)
            #expect(deliveries[1].wasTruncated)
        }
    }

    private actor LiveTranscriptDeliveryRecorder {
        private var deliveries: [FinalizedLiveTranscriptRelay.Delivery] = []
        private var blocksFirstDelivery: Bool
        private var continuation: CheckedContinuation<Void, Never>?

        init(blocksFirstDelivery: Bool) {
            self.blocksFirstDelivery = blocksFirstDelivery
        }

        func append(_ delivery: FinalizedLiveTranscriptRelay.Delivery) async {
            deliveries.append(delivery)
            if deliveries.count == 1, blocksFirstDelivery {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }
        }

        func open() {
            blocksFirstDelivery = false
            continuation?.resume()
            continuation = nil
        }

        func snapshot() -> [FinalizedLiveTranscriptRelay.Delivery] {
            deliveries
        }

        func waitForCount(_ count: Int) async {
            for _ in 0 ..< 1_000 {
                if deliveries.count >= count { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for live transcript delivery")
        }
    }
#endif
