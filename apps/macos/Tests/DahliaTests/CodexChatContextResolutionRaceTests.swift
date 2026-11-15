import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatContextResolutionRaceTests {
        @Test(arguments: [false, true])
        func stoppingDequeuedInputBeforeAcceptancePreservesQueueAndDraft(hasImage: Bool) async throws {
            let service = ImageChatService(supportsImages: true, sendBehavior: .block)
            let settings = TestCodexChatFixtures.appSettings()
            settings.currentWorkspace = Self.testWorkspace()
            let contextProvider = DelayedCodexChatContextProvider()
            let session = Self.session(service: service, settings: settings, contextProvider: contextProvider)
            session.draft = "Start"
            session.sendDraft()
            try #require(await pollUntil { contextProvider.isWaiting })
            contextProvider.resume()
            try #require(await pollUntil { session.activeTurnID != nil })
            let image = CodexChatImageAttachment(data: Data([1]), mimeType: "image/png")
            session.draft = "Next"
            session.selectedMeetingReferenceIDs = [.v7()]
            session.attachedImages = hasImage ? [image] : []
            session.sendDraft(mode: .queue)
            let next = try #require(session.pendingManualInputs.first)
            session.draft = "Last"
            session.sendDraft(mode: .queue)
            let last = try #require(session.pendingManualInputs.last)
            await service.completeBlockedTurn()
            try #require(await pollUntil { contextProvider.isWaiting })
            session.draft = "Independent draft"
            session.stop()
            try #require(await pollUntil { !session.isGenerating && !session.isTurnCleanupPending })
            contextProvider.resume()
            #expect(session.isQueuePaused)
            #expect(session.pendingManualInputs == [next, last])
            #expect(session.draft == "Independent draft")
            #expect(await service.sentInputs.count == 1)
            session.resumeQueue()
            try #require(await pollUntil { contextProvider.isWaiting })
            contextProvider.resume()
            try #require(await pollUntil { await service.sentInputs.count == 2 })
            try #require(await pollUntil { session.activeTurnID != nil })
            #expect(await service.sentInputs.last?.compactMap(\.textValue) == [next.text])
            #expect(session.messages.last(where: { $0.role == .user })?.images == next.images)
            #expect(session.pendingManualInputs == [last])
            #expect(session.draft == "Independent draft")
            await service.completeBlockedTurn()
            try #require(await pollUntil { contextProvider.isWaiting })
            contextProvider.resume()
            try #require(await pollUntil { await service.sentInputs.count == 3 })
            try #require(await pollUntil { session.activeTurnID != nil })
            await service.completeBlockedTurn()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
        }

        @Test
        func stoppingAnUnacceptedPendingSteerPreservesItAfterTheComposerChanges() async throws {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let settings = TestCodexChatFixtures.appSettings()
            settings.currentWorkspace = Self.testWorkspace()
            let contextProvider = DelayedCodexChatContextProvider()
            let session = Self.session(service: service, settings: settings, contextProvider: contextProvider)
            session.draft = "/mcp"
            session.sendDraft()
            try #require(await pollUntil { session.activeTurnID != nil })
            session.draft = "Next"
            session.sendDraft(mode: .steer)
            let next = try #require(session.pendingManualInputs.first)
            session.draft = "Independent draft"
            await service.completeBlockedTurn()
            try #require(await pollUntil { contextProvider.isWaiting })
            session.stop()
            try #require(await pollUntil { !session.isGenerating && !session.isTurnCleanupPending })
            contextProvider.resume()
            #expect(session.pendingManualInputs == [next])
            #expect(session.draft == "Independent draft")
            #expect(session.isQueuePaused)
        }

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
        func accountSwitchDuringContextResolutionCancelsBeforeSending() async {
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
            var otherAccountWorkspace = Self.testWorkspace()
            otherAccountWorkspace.accountConnectionId = .v7()
            settings.currentWorkspace = otherAccountWorkspace
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
            session.selectApprovalMethod(.autoReview)
            contextProvider.resume()
            await waitUntil { !session.isGenerating }

            #expect(await service.turnApprovalMethods == [.ask])
            #expect(session.selectedApprovalMethod == .autoReview)
        }

        private static func session(
            backendThreadID: String? = nil,
            service: any CodexChatServicing,
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
