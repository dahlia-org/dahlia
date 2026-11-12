import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatSteeringTests {

        @Test(arguments: ["/mcp", "/skill:summary compare"])
        func slashCommandsStayPendingInsteadOfEnteringTheSteeringRPC(command: String) {
            let session = makeSession(service: TestCodexChatService(mode: .block))
            let commandInput = CodexChatManualSubmission(text: command, images: [])
            let followUp = CodexChatManualSubmission(text: "Follow-up", images: [])
            session.pendingManualInputs = [commandInput, followUp]

            #expect(session.nextPendingSteerInput() == nil)
            #expect(session.pendingManualInputs == [commandInput, followUp])
        }

        @Test(arguments: [false, true])
        func queuedCommandRunsAfterTheActiveTurnAndKeepsLaterInputInOrder(stopActiveTurn: Bool) async {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = makeSession(service: service)
            session.draft = "First question"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }

            session.draft = "/mcp"
            session.sendDraft()
            #expect(session.pendingCommand?.text == "/mcp")
            session.draft = "Later question"
            session.sendDraft()
            #expect(session.pendingManualInputs.map(\.text) == ["/mcp", "Later question"])
            #expect(await service.steeredTextBlocks.isEmpty)

            if stopActiveTurn {
                session.stop()
            } else {
                await service.completeBlockedTurn()
            }
            await waitUntilAsync { await service.sentTextBlocks.count == 2 }
            await waitUntil { session.activeTurnID != nil }
            #expect(await service.sentTextBlocks == [["First question"], ["/mcp"]])
            #expect(session.pendingManualInputs.map(\.text) == ["Later question"])
            #expect(await service.steeredTextBlocks.isEmpty)
            await service.yieldBlockedEvent(.notice(message: "dahlia: connected"))
            await service.completeBlockedTurn()

            await waitUntilAsync { await service.sentTextBlocks.count == 3 }
            await waitUntil { session.activeTurnID != nil }
            #expect(await service.sentTextBlocks == [["First question"], ["/mcp"], ["Later question"]])
            #expect(session.pendingCommand == nil)
            await service.completeBlockedTurn()
            await waitUntil { !session.hasPendingGenerationWork }
            #expect(session.messages.filter { $0.role == .notice(.info) }.map(\.text) == ["dahlia: connected"])
            #expect(session.errorMessage == nil)
        }

        @Test
        func cancellingAQueuedCommandAllowsTheFollowingInputToSteer() async throws {
            let service = TestCodexChatService(mode: .block)
            let session = makeSession(service: service)
            session.draft = "First question"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }
            session.draft = "/mcp"
            session.sendDraft()
            let command = try #require(session.pendingCommand)
            session.draft = "Follow-up"
            session.sendDraft()
            session.cancelPendingCommand(command)

            await waitUntilAsync { await service.steeredTextBlocks.count == 1 }
            #expect(session.pendingCommand == nil)
            #expect(await service.steeredTextBlocks == [["Follow-up"]])
            #expect(await service.sentTextBlocks == [["First question"]])
            session.stop()
            await waitUntil { !session.hasPendingGenerationWork }
        }

        @Test
        func releasingTheSessionDiscardsAQueuedCommand() async {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = makeSession(service: service)
            session.draft = "First question"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }
            session.draft = "/mcp"
            session.sendDraft()
            #expect(session.pendingCommand != nil)
            session.release()
            await waitUntil { !session.hasPendingGenerationWork }
            #expect(session.pendingManualInputs.isEmpty)
            #expect(await service.sentTextBlocks == [["First question"]])
            #expect(await service.steeredTextBlocks.isEmpty)
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
            settings.currentWorkspace = WorkspaceRecord(
                id: .v7(),
                path: "/tmp/chat-steering-test-workspace",
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
