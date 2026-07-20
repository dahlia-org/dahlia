import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatSteeringTests {
        @Test
        func liveTranscriptsSteerTheActiveTurnAsTheyArrive() async {
            let service = TestCodexChatService(mode: .block)
            let session = makeSession(service: service)

            session.toggleLiveMode()
            session.receiveFinalizedLiveTranscript("first")
            await waitUntil { session.activeTurnID != nil }
            session.receiveFinalizedLiveTranscript("second")
            session.receiveFinalizedLiveTranscript("third")

            await waitUntilAsync { await service.steeredTextBlocks.count == 2 }

            #expect(await service.steeredTextBlocks == [
                ["<live_transcript source=\"dahlia\">second</live_transcript>"],
                ["<live_transcript source=\"dahlia\">third</live_transcript>"],
            ])
            session.disableLiveMode()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func manualInputSteersTheActiveTurnWithoutStoppingItsResponse() async {
            let service = TestCodexChatService(mode: .block)
            let session = makeSession(service: service)

            session.draft = "First question"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }

            session.draft = "Follow-up while responding"
            #expect(session.canSend)
            session.sendDraft()
            await waitUntilAsync { await service.steeredTextBlocks.count == 1 }

            #expect(session.isGenerating)
            #expect(session.draft.isEmpty)
            #expect(session.messages.filter { $0.role == .user }.map(\.text) == [
                "First question",
                "Follow-up while responding",
            ])
            #expect(await service.steeredTextBlocks == [["Follow-up while responding"]])
            session.stop()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func liveTranscriptDoesNotWaitForManualDraftDuringGeneration() async {
            let service = TestCodexChatService(mode: .block)
            let session = makeSession(service: service)

            session.toggleLiveMode()
            session.draft = "Initial request"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }

            session.draft = "Still editing"
            session.receiveFinalizedLiveTranscript("send immediately")
            await waitUntilAsync { await service.steeredTextBlocks.count == 1 }

            #expect(session.draft == "Still editing")
            #expect(await service.sentTextBlocks == [["Initial request"]])
            #expect(await service.steeredTextBlocks[0] == [
                TestCodexChatFixtures.liveTranscriptContext,
                "<live_transcript source=\"dahlia\">send immediately</live_transcript>",
            ])
            session.stop()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func liveTranscriptStartsANewTurnWhenTheActiveTurnFinishedBeforeSteering() async {
            let service = TestCodexChatService(
                mode: .block,
                steerErrors: [.rpcError(code: nil, message: "no active turn to steer")]
            )
            let session = makeSession(service: service)

            session.toggleLiveMode()
            session.receiveFinalizedLiveTranscript("first")
            await waitUntil { session.activeTurnID != nil }

            session.receiveFinalizedLiveTranscript("send on the next turn")
            await waitUntilAsync { await service.steeredTextBlocks.count == 1 }
            await waitUntilAsync { await service.sentTextBlocks.count == 2 }

            #expect(await service.sentTextBlocks[1] == [
                "<live_transcript source=\"dahlia\">send on the next turn</live_transcript>",
            ])
            #expect(session.isGenerating)
            #expect(session.errorMessage == nil)

            session.disableLiveMode()
            await waitUntil { !session.isGenerating }
        }

        private func makeSession(service: TestCodexChatService) -> CodexChatSessionModel {
            let settings = AppSettings()
            settings.currentVault = VaultRecord(
                id: .v7(),
                path: "/tmp/chat-steering-test-vault",
                name: "Chat Steering Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            return CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )
        }

        private func waitUntil(_ predicate: @MainActor () -> Bool) async {
            for _ in 0 ..< 1000 {
                if predicate() { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for chat state")
        }

        private func waitUntilAsync(
            _ predicate: @escaping @Sendable () async -> Bool
        ) async {
            for _ in 0 ..< 1000 {
                if await predicate() { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for asynchronous chat state")
        }
    }
#endif
