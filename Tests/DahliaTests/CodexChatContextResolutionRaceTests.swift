import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatContextResolutionRaceTests {
        @Test
        func stopDuringContextResolutionCancelsBeforeSending() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let contextProvider = DelayedCodexChatContextProvider()
            let session = Self.session(service: service, settings: settings, contextProvider: contextProvider)
            session.draft = "Do not start"

            session.sendDraft()
            await waitUntil { contextProvider.isWaiting }
            session.stop()
            contextProvider.resume()
            await waitUntil { !session.isGenerating }

            #expect(session.draft == "Do not start")
            #expect(session.messages.isEmpty)
            #expect(await service.sentTexts.isEmpty)
        }

        @Test
        func vaultSwitchDuringContextResolutionCancelsBeforeSending() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let contextProvider = DelayedCodexChatContextProvider()
            let session = Self.session(
                backendThreadID: "existing-thread",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            session.draft = "Stay in old vault"

            session.sendDraft()
            await waitUntil { contextProvider.isWaiting }
            settings.currentVault = Self.testVault()
            contextProvider.resume()
            await waitUntil { !session.isGenerating }

            #expect(session.draft == "Stay in old vault")
            #expect(session.messages.isEmpty)
            #expect(await service.sentTexts.isEmpty)
        }

        private static func session(
            backendThreadID: String? = nil,
            service: TestCodexChatService,
            settings: AppSettings,
            contextProvider: DelayedCodexChatContextProvider
        ) -> CodexChatSessionModel {
            CodexChatSessionModel(
                backendThreadID: backendThreadID,
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
        }

        private static func testVault() -> VaultRecord {
            VaultRecord(
                id: .v7(),
                path: "/tmp/chat-context-race-test-vault",
                name: "Chat Context Race Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
        }

        private func waitUntil(_ predicate: @MainActor () -> Bool) async {
            for _ in 0 ..< 1000 {
                if predicate() { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for context resolution")
        }
    }

    @MainActor
    private final class DelayedCodexChatContextProvider: CodexChatContextProviding {
        private var continuation: CheckedContinuation<CodexChatContext?, Never>?

        var isWaiting: Bool { continuation != nil }

        func currentContext(vaultID _: UUID) async throws -> CodexChatContext? {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume() {
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }
#endif
