import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatStreamingSessionTests {
        @Test
        func trailingUpdateAppearsWhileStreamIsStillWaiting() async {
            let session = makeSession(mode: .burstThenBlock, updateInterval: .milliseconds(10))

            session.draft = "Question"
            session.sendDraft()
            await waitUntil { session.messages.last?.text == "First" }
            await waitUntilEventually { session.messages.last?.text == "First second" }

            #expect(session.isGenerating)
            #expect(session.messages.last?.text == "First second")
            session.stop()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func streamEndingWithoutTerminalEventFinalizesResponse() async {
            let session = makeSession(mode: .finishesWithoutTerminal)

            session.draft = "Question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.messages.last?.text == "Partial answer")
            #expect(session.messages.last?.isStreaming == false)
        }

        @Test
        func terminalEventFinalizesWithoutWaitingForStreamClose() async {
            let session = makeSession(mode: .interruptedThenBlock)

            session.draft = "Question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.messages.last?.text == "Partial answer")
            #expect(session.messages.last?.isStreaming == false)
        }

        @Test
        func bufferedBurstYieldsMainActorAndPreservesEveryDelta() async {
            let session = makeSession(mode: .bufferedBurstThenInterrupt)

            session.draft = "Question"
            session.sendDraft()

            await waitUntil { session.activeTurnID != nil }
            #expect(session.isGenerating)
            await waitUntilEventually { !session.isGenerating }
            #expect(session.messages.last?.text == String(repeating: "x", count: 2048))
        }

        private func makeSession(
            mode: TestCodexChatService.Mode,
            updateInterval: Duration = .milliseconds(50)
        ) -> CodexChatSessionModel {
            let settings = AppSettings()
            settings.currentVault = VaultRecord(
                id: .v7(),
                path: "/tmp/chat-streaming-test-vault",
                name: "Chat Streaming Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            return CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: TestCodexChatService(mode: mode),
                settings: settings,
                streamingUpdateInterval: updateInterval
            )
        }

        private func waitUntil(_ predicate: @MainActor () -> Bool) async {
            for _ in 0 ..< 1000 {
                if predicate() { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for chat state")
        }

        private func waitUntilEventually(
            timeout: Duration = .seconds(1),
            _ predicate: @MainActor () -> Bool
        ) async {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if predicate() { return }
                try? await Task.sleep(for: .milliseconds(1))
            }
            Issue.record("Timed out waiting for chat state")
        }
    }
#endif
