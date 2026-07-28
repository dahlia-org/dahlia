import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatThinkingPresentationTests {
        @Test
        func standaloneThinkingHandsOffToActiveResponse() async {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let contextProvider = TestCodexChatContextProvider(shouldBlock: true)
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            session.draft = "Question"

            session.sendDraft()
            await waitUntil { contextProvider.requestCount == 1 }
            #expect(session.showsStandaloneThinking)

            contextProvider.resume()
            await waitUntil { session.activeTurnID != nil }
            #expect(!session.showsStandaloneThinking)

            session.stop()
            await waitUntil { !session.isGenerating }
            #expect(!session.showsStandaloneThinking)
        }

        @Test
        func completedResponseDoesNotShowThinkingDuringReconciliation() async {
            let service = TestCodexChatService(mode: .complete, delaysLoad: true)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )
            session.draft = "Question"

            session.sendDraft()
            await waitUntilAsync { await service.isLoadWaiting }

            #expect(session.isGenerating)
            #expect(session.messages.last?.text == "Final answer")
            #expect(session.messages.last?.isStreaming == false)
            #expect(!session.showsStandaloneThinking)

            await service.resumeDelayedLoad()
            await waitUntil { !session.isGenerating }
        }

        private static func testVault() -> VaultRecord {
            VaultRecord(
                id: .v7(),
                path: "/tmp/chat-thinking-presentation-tests",
                name: "Chat Thinking Presentation Tests",
                createdAt: .now,
                lastOpenedAt: .now
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
