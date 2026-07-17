import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatStreamingUpdateLimiterTests {
        @Test
        func publishesTheLatestSuppressedUpdateAtTheTrailingEdge() async {
            var publishedTexts: [String] = []
            let accumulator = CodexChatTurnAccumulator()
            let sleeper = TestCodexChatStreamingSleeper()
            let limiter = CodexChatStreamingUpdateLimiter(
                minimumInterval: .milliseconds(10),
                sleep: { _ in try await sleeper.sleep() },
                publish: { publishedTexts.append(accumulator.responseText) }
            )

            accumulator.appendResponseDelta(itemID: "item", text: "First")
            limiter.submit()
            accumulator.appendResponseDelta(itemID: "item", text: " second")
            limiter.submit()

            #expect(publishedTexts == ["First"])
            await waitUntil { sleeper.isWaiting }
            sleeper.resume()
            await waitUntil { publishedTexts.count == 2 }
            #expect(publishedTexts == ["First", "First second"])
        }

        @Test
        func forcedUpdateCancelsPendingTrailingPublish() async {
            var publishedTexts: [String] = []
            let accumulator = CodexChatTurnAccumulator()
            let sleeper = TestCodexChatStreamingSleeper()
            let limiter = CodexChatStreamingUpdateLimiter(
                minimumInterval: .milliseconds(20),
                sleep: { _ in try await sleeper.sleep() },
                publish: { publishedTexts.append(accumulator.responseText) }
            )

            accumulator.appendResponseDelta(itemID: "item", text: "First")
            limiter.submit()
            accumulator.appendResponseDelta(itemID: "item", text: " second")
            limiter.submit()
            await waitUntil { sleeper.isWaiting }
            limiter.submit(force: true)

            sleeper.resume()
            for _ in 0 ..< 10 {
                await Task.yield()
            }
            #expect(publishedTexts == ["First", "First second"])
        }

        private func waitUntil(_ predicate: @MainActor () -> Bool) async {
            for _ in 0 ..< 1000 {
                if predicate() { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for limiter state")
        }
    }

    @MainActor
    private final class TestCodexChatStreamingSleeper {
        private var continuation: CheckedContinuation<Void, Never>?

        var isWaiting: Bool {
            continuation != nil
        }

        func sleep() async throws {
            await withCheckedContinuation { continuation = $0 }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }
#endif
