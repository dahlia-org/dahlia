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
                await waitUntil { !session.isGenerating && !session.isTurnCleanupPending }
                #expect(session.isQueuePaused)
                #expect(session.pendingManualInputs.map(\.text) == ["/mcp", "Later question"])
                session.resumeQueue()
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

            #expect(session.messages.filter { $0.role == .user }.map(\.isSteer) == [false, true])
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

        @Test
        func queuedInputsWaitForCompletionAndRunInOrder() async {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = makeSession(service: service)
            session.draft = "Start"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }
            for text in ["Next", "Last"] {
                session.draft = text
                session.sendDraft(mode: .queue)
                #expect(session.draft.isEmpty)
            }
            #expect(session.pendingManualInputs.map(\.text) == ["Next", "Last"])
            #expect(await service.steeredTextBlocks.isEmpty)
            session.draft = "Next"
            await service.completeBlockedTurn()
            await waitUntilAsync { await service.sentTextBlocks.count == 2 }
            await waitUntil { session.activeTurnID != nil }
            #expect(session.draft == "Next")
            #expect(session.pendingManualInputs.map(\.text) == ["Last"])
            await service.completeBlockedTurn()
            await waitUntilAsync { await service.sentTextBlocks.count == 3 }
            await waitUntil { session.activeTurnID != nil }
            #expect(await service.sentTextBlocks == [["Start"], ["Next"], ["Last"]])
            await service.completeBlockedTurn()
            await waitUntil { !session.hasPendingGenerationWork }
        }

        @Test
        func sendNowPromotesOnlyTheSelectedQueuedMessageAndPreservesDraft() async throws {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = makeSession(service: service)
            session.draft = "Start"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }
            for text in ["First", "Second"] {
                session.draft = text
                session.sendDraft(mode: .queue)
            }
            let second = try #require(session.pendingManualInputs.last)
            session.draft = "Second"
            session.sendPendingInputNow(id: second.id)
            await waitUntilAsync { await service.steeredTextBlocks.count == 1 }
            #expect(await service.steeredTextBlocks == [["Second"]])
            #expect(session.draft == "Second")
            #expect(session.pendingManualInputs.map(\.text) == ["First"])
            session.stop()
            await waitUntil { !session.hasPendingGenerationWork }
            #expect(session.isQueuePaused)
            #expect(session.pendingManualInputs.map(\.text) == ["First"])
            try session.removePendingInput(id: #require(session.pendingManualInputs.first).id)
            #expect(session.pendingManualInputs.isEmpty)
        }

        @Test(arguments: [false, true])
        func explicitRecoveryAfterFailurePreservesAndDrainsTheQueue(retries: Bool) async throws {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = makeSession(service: service, deliveryMode: .queue)
            session.draft = "Start"
            session.sendDraft()
            try #require(await pollUntil { session.activeTurnID != nil })
            session.draft = "Queued"
            session.sendDraft(mode: .queue)
            await service.completeBlockedTurn(with: .failed(message: "Connection lost"))
            try #require(await pollUntil { !session.isGenerating && !session.isTurnCleanupPending && session.errorMessage != nil })
            #expect(session.pendingManualInputs.map(\.text) == ["Queued"])
            if retries {
                session.retry()
            } else {
                session.draft = "Recover"
                session.sendDraft()
            }
            try #require(await pollUntil { await service.sentTextBlocks.count == 2 })
            try #require(await pollUntil { session.activeTurnID != nil })
            #expect(session.errorMessage == nil)
            #expect(session.pendingManualInputs.map(\.text) == ["Queued"])
            await service.completeBlockedTurn()
            try #require(await pollUntil { await service.sentTextBlocks.count == 3 })
            try #require(await pollUntil { session.activeTurnID != nil })
            #expect(await service.sentTextBlocks == [["Start"], [retries ? "Start" : "Recover"], ["Queued"]])
            await service.completeBlockedTurn()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
        }

        @Test
        func editingHoldsTheQueueAndPreservesReferencesAndComposer() async throws {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = makeSession(service: service)
            session.draft = "Start"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }
            let meetingID = UUID.v7()
            session.selectedMeetingReferenceIDs = [meetingID]
            session.draft = "Original"
            session.sendDraft(mode: .queue)
            let queued = try #require(session.pendingManualInputs.first)
            session.beginEditingPendingInput(id: queued.id)
            session.draft = "Unrelated draft"
            await service.completeBlockedTurn()
            await waitUntil { !session.isGenerating }
            #expect(await service.sentTextBlocks.count == 1)
            session.savePendingInput(id: queued.id, draft: "Edited", images: [])
            await waitUntilAsync { await service.sentTextBlocks.count == 2 }
            await waitUntil { session.activeTurnID != nil }
            #expect(session.draft == "Unrelated draft")
            let sent = try #require(await service.sentTextBlocks.last?.last)
            #expect(sent.contains("Edited"))
            #expect(sent.contains(CodexChatMeetingReference.serializedText(referenceIDs: [meetingID], draft: "")))
            await service.completeBlockedTurn()
            await waitUntil { !session.hasPendingGenerationWork }
        }

        @Test
        func pendingEditStateLivesWithTheSessionAndClearsOnCompletion() {
            let session = makeSession(service: TestCodexChatService(mode: .block))
            session.isQueuePaused = true
            session.draft = "Independent draft"
            let image = CodexChatImageAttachment(data: Data([1]), mimeType: "image/png")
            let input = CodexChatManualSubmission(deliveryMode: .queue, text: "Original", images: [image])
            session.pendingManualInputs = [input]
            session.beginEditingPendingInput(id: input.id)
            #expect(session.pendingInputEditDraft == "Original")
            #expect(session.pendingInputEditImages == [image])
            session.pendingInputEditDraft = "Unsaved edit"
            session.beginEditingPendingInput(id: input.id)
            #expect(session.pendingInputEditDraft == "Unsaved edit")
            #expect(session.pendingInputEditImages == [image])
            session.savePendingInput(id: input.id, draft: session.pendingInputEditDraft, images: session.pendingInputEditImages)
            #expect(session.pendingManualInputs.first?.text == "Unsaved edit")
            #expect(session.pendingManualInputs.first?.images == [image])
            #expect(session.pendingInputEditDraft.isEmpty)
            #expect(session.pendingInputEditImages.isEmpty)
            session.beginEditingPendingInput(id: input.id)
            session.pendingInputEditDraft = "Cancelled edit"
            session.cancelEditingPendingInput()
            #expect(session.pendingInputEditDraft.isEmpty)
            #expect(session.pendingInputEditImages.isEmpty)
            session.beginEditingPendingInput(id: input.id)
            #expect(session.pendingInputEditDraft == "Unsaved edit")
            session.removePendingInput(id: input.id)
            #expect(session.editingPendingInputID == nil)
            #expect(session.pendingInputEditDraft.isEmpty)
            #expect(session.pendingInputEditImages.isEmpty)
            #expect(session.draft == "Independent draft")
        }

        @Test
        func stoppingAnAcceptedQueuedTurnDoesNotRequeueIt() async throws {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = makeSession(service: service)
            session.draft = "Start"
            session.sendDraft()
            try #require(await pollUntil { session.activeTurnID != nil })
            session.draft = "Next"
            session.sendDraft(mode: .queue)
            await service.completeBlockedTurn()
            try #require(await pollUntil { await service.sentTextBlocks.count == 2 })
            try #require(await pollUntil { session.activeTurnID != nil })
            session.stop()
            try #require(await pollUntil { !session.isGenerating && !session.isTurnCleanupPending })
            #expect(session.pendingManualInputs.isEmpty)
        }

        @Test
        func cancelledEditLeavesQueueUnchangedAndStaleActionsCannotResurrectIt() {
            let session = makeSession(service: TestCodexChatService(mode: .block))
            session.isQueuePaused = true
            let original = CodexChatManualSubmission(deliveryMode: .queue, text: "Original", images: [])
            session.pendingManualInputs = [original]
            session.beginEditingPendingInput(id: original.id)
            session.cancelEditingPendingInput()
            #expect(session.pendingManualInputs == [original])
            session.beginEditingPendingInput(id: original.id)
            session.removePendingInput(id: original.id)
            session.savePendingInput(id: original.id, draft: "Stale", images: [])
            session.sendPendingInputNow(id: original.id)
            #expect(session.pendingManualInputs.isEmpty)
            #expect(session.editingPendingInputID == nil)
        }

        @Test
        func savingQueuedImageEditsPreservesThreadReferencesAndIdentity() throws {
            let session = makeSession(service: TestCodexChatService(mode: .block))
            session.isQueuePaused = true
            let image = CodexChatImageAttachment(data: Data([1]), mimeType: "image/png")
            let snapshot = CodexChatComposerSnapshot(
                draft: "Original",
                referenceIDs: [],
                images: [image],
                threadReferences: [CodexChatThreadSummary(id: "other-thread", title: "Other", updatedAt: .now)]
            )
            let original = CodexChatManualSubmission(
                deliveryMode: .queue,
                text: "thread:other-thread Original",
                images: [image],
                composerSnapshot: snapshot
            )
            session.pendingManualInputs = [original]
            session.beginEditingPendingInput(id: original.id)
            session.savePendingInput(id: original.id, draft: "Edited", images: [image])
            let saved = try #require(session.pendingManualInputs.first)
            #expect(saved.id == original.id)
            #expect(saved.images == [image])
            #expect(saved.text == "thread:other-thread Edited")
            #expect(saved.deliveryMode == .queue)
            session.beginEditingPendingInput(id: original.id)
            session.savePendingInput(id: original.id, draft: "Edited again", images: [])
            #expect(session.pendingManualInputs.first?.images.isEmpty == true)
            #expect(session.isQueuePaused)
        }

        @Test
        func editingAPendingSteerPreservesAnIndependentIdenticalDraft() async throws {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = makeSession(service: service)
            session.draft = "/mcp"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }
            session.draft = "Original"
            session.sendDraft()
            let queued = try #require(session.pendingManualInputs.first)
            session.beginEditingPendingInput(id: queued.id)
            session.draft = "Edited"
            session.savePendingInput(id: queued.id, draft: "Edited", images: [])
            await service.completeBlockedTurn()
            await waitUntilAsync { await service.sentTextBlocks.count == 2 }
            await waitUntil { session.activeTurnID != nil }
            #expect(session.draft == "Edited")
            #expect(await service.sentTextBlocks == [["/mcp"], ["Edited"]])
            await service.completeBlockedTurn()
            await waitUntil { !session.hasPendingGenerationWork }
        }

        @Test
        func newChatsQueueByDefaultAndSwitchingToSteerUsesADifferentSendIcon() async {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let session = makeSession(service: service, deliveryMode: nil)
            #expect(session.deliveryMode == .queue)
            let queueIcon = session.deliveryMode.symbol
            session.draft = "Start"
            session.sendDraft()
            await waitUntil { session.activeTurnID != nil }
            session.draft = "Queued by default"
            session.sendDraft()
            #expect(session.pendingManualInputs.map(\.text) == ["Queued by default"])
            #expect(session.draft.isEmpty)
            #expect(await service.steeredTextBlocks.isEmpty)
            session.deliveryMode = .steer
            #expect(session.deliveryMode.symbol != queueIcon)
            session.draft = "Steer after switching"
            session.sendDraft()
            await waitUntilAsync { await service.steeredTextBlocks.count == 1 }
            #expect(await service.steeredTextBlocks == [["Steer after switching"]])
            #expect(session.pendingManualInputs.map(\.text) == ["Queued by default"])
            session.stop()
            await waitUntil { !session.hasPendingGenerationWork }
        }

        private func makeSession(service: TestCodexChatService, deliveryMode: CodexChatDeliveryMode? = .steer) -> CodexChatSessionModel {
            let settings = TestCodexChatFixtures.appSettings()
            settings.currentWorkspace = WorkspaceRecord(
                id: .v7(),
                path: "/tmp/chat-steering-test-workspace",
                name: "Chat Steering Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )
            if let deliveryMode { session.deliveryMode = deliveryMode }
            return session
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
