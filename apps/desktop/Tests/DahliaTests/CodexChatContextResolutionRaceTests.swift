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
            settings.currentWorkspace = Self.testWorkspace()
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
            #expect(await service.sentTextBlocks.isEmpty)
        }

        @Test
        func workspaceSwitchDuringContextResolutionCancelsBeforeSending() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            settings.currentWorkspace = Self.testWorkspace()
            let contextProvider = DelayedCodexChatContextProvider()
            let session = Self.session(
                backendThreadID: "existing-thread",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            session.draft = "Stay in old workspace"

            session.sendDraft()
            await waitUntil { contextProvider.isWaiting }
            settings.currentWorkspace = Self.testWorkspace()
            contextProvider.resume()
            await waitUntil { !session.isGenerating }

            #expect(session.draft == "Stay in old workspace")
            #expect(session.messages.isEmpty)
            #expect(await service.sentTextBlocks.isEmpty)
        }

        @Test
        func approvalChangeDuringContextResolutionAppliesAfterSubmittedTurn() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            settings.currentWorkspace = Self.testWorkspace()
            let contextProvider = DelayedCodexChatContextProvider()
            let session = Self.session(
                backendThreadID: "existing-thread",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            session.draft = "Use the submitted permission"

            session.sendDraft()
            await waitUntil { contextProvider.isWaiting }
            session.selectApprovalMethod(.fullAccess)
            contextProvider.resume()
            await waitUntil { !session.isGenerating }

            #expect(await service.turnApprovalMethods == [.ask])
            #expect(session.selectedApprovalMethod == .fullAccess)
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
                approvalMethod: backendThreadID == nil ? nil : .ask,
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
        }

        private static func testWorkspace() -> WorkspaceRecord {
            WorkspaceRecord(
                id: .v7(),
                path: "/tmp/chat-context-race-test-workspace",
                name: "Chat Context Race Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
        }

        private func waitUntil(_ predicate: @MainActor () -> Bool) async {
            if await pollUntil({ predicate() }) { return }
            Issue.record("Timed out waiting for context resolution")
        }
    }

    @MainActor
    private final class DelayedCodexChatContextProvider: CodexChatContextProviding {
        private var continuation: CheckedContinuation<CodexChatContext?, Never>?

        var isWaiting: Bool { continuation != nil }

        func currentContext(workspaceID _: UUID) async throws -> CodexChatContext? {
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
