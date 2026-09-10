import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatSteeringTests {

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
            await waitUntil { session.messages.count { $0.role == .user } == 2 }

            #expect(session.isGenerating)
            #expect(session.draft.isEmpty)
            #expect(session.messages.filter { $0.role == .user }.map(\.text) == [
                "First question",
                "Follow-up while responding",
            ])
            #expect(await service.steeredTextBlocks == [["Follow-up while responding"]])
            session.stop()
            await waitUntil { !session.isGenerating }
            #expect(!session.showsStandaloneThinking)
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
            if await pollUntil({ predicate() }) { return }
            Issue.record("Timed out waiting for chat state")
        }

        private func waitUntilAsync(
            _ predicate: @escaping @Sendable () async -> Bool
        ) async {
            if await pollUntil({ await predicate() }) { return }
            Issue.record("Timed out waiting for asynchronous chat state")
        }
    }
#endif
