import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.timeLimit(.minutes(1)))
    struct CodexChatStreamingSessionTests {
        @Test
        func trailingUpdateAppearsWhileStreamIsStillWaiting() async {
            let session = makeSession(mode: .burstThenBlock, updateInterval: .milliseconds(10))

            session.draft = "Question"
            session.sendDraft()
            await waitUntil { session.messages.last?.text == "First" }
            await waitUntil { session.messages.last?.text == "First second" }

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
            await waitUntil { !session.isGenerating }
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
            while !predicate() {
                await Task.yield()
            }
        }
    }
#endif
