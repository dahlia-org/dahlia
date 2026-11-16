import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatThinkingPresentationTests {
        @Test(arguments: [false, true], [false, true])
        func thinkingStartsSynchronouslyAndRemainsVisibleDuringPreparation(stop: Bool, existingThread: Bool) async throws {
            let service = TestCodexChatService(mode: .delayTurnHandleIgnoringCancellation)
            let settings = AppSettings()
            settings.currentWorkspace = Self.testWorkspace()
            let session = CodexChatSessionModel(
                backendThreadID: existingThread ? "existing-thread" : nil,
                messages: existingThread ? [CodexChatMessage(role: .assistant, text: "Previous response")] : [],
                service: service,
                settings: settings
            )
            session.draft = "Question"

            #expect(!session.showsStandaloneThinking)
            session.sendDraft()
            // The welcome screen must disappear before context lookup or Pi startup can suspend.
            let submittedMessage = try #require(session.conversationMessages.last)
            #expect(submittedMessage.role == .user)
            #expect(submittedMessage.text == "Question")
            #expect(session.showsStandaloneThinking)
            #expect(session.draft.isEmpty)

            await waitUntilAsync { await service.isSendWaiting }
            #expect(session.isPreparingTurn)
            #expect(session.showsStandaloneThinking)
            #expect(session.draft.isEmpty)
            #expect(session.conversationMessages.last == submittedMessage)

            if stop { session.stop() }
            await service.resumeDelayedSend()
            if !stop {
                await waitUntil { session.activeTurnID != nil }
                #expect(!session.isPreparingTurn)
                #expect(session.showsStandaloneThinking)
                #expect(session.conversationMessages.filter { $0.role == .user }.map(\.id) == [submittedMessage.id])
                await service.completeBlockedTurn()
            }
            await waitUntil { !session.hasPendingGenerationWork }
            #expect(!session.showsStandaloneThinking)
            #expect(session.draft == (stop ? "Question" : ""))
            #expect(session.preparingUserMessage == nil)
            #expect(session.conversationMessages == session.messages)
            if stop {
                #expect(!session.conversationMessages.contains { $0.role == .user })
            }
        }

        @Test
        func failedPreparationRemovesPreviewAndRetryShowsOneMessage() async throws {
            let service = TestCodexChatService(mode: .complete)
            let settings = TestCodexChatFixtures.appSettings()
            settings.currentWorkspace = Self.testWorkspace()
            let contextProvider = TestCodexChatContextProvider(error: .invalidProtocolResponse, shouldBlock: true)
            let session = CodexChatSessionModel(service: service, settings: settings, contextProvider: contextProvider)
            session.draft = "Question"

            session.sendDraft()
            #expect(session.conversationMessages.map(\.text) == ["Question"])
            #expect(session.draft.isEmpty)
            try #require(await pollUntil { contextProvider.requestCount == 1 })
            contextProvider.resume()
            try #require(await pollUntil { !session.isGenerating })
            #expect(session.errorMessage != nil)
            #expect(session.conversationMessages.isEmpty)
            #expect(session.draft == "Question")

            contextProvider.error = nil
            session.retry()
            #expect(session.conversationMessages.map(\.text) == ["Question"])
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            #expect(session.conversationMessages.filter { $0.role == .user }.map(\.text) == ["Question"])
            #expect(session.draft.isEmpty)
        }

        @Test(arguments: [false, true], ["", "Question", "Next question"])
        func preparationPreservesComposerRecoveryAndNewDrafts(fails: Bool, nextDraft: String) async throws {
            let service = TestCodexChatService(mode: .complete)
            let settings = TestCodexChatFixtures.appSettings()
            settings.currentWorkspace = Self.testWorkspace()
            let contextProvider = TestCodexChatContextProvider(
                error: fails ? .invalidProtocolResponse : nil,
                shouldBlock: true
            )
            let session = CodexChatSessionModel(service: service, settings: settings, contextProvider: contextProvider)
            let reference = CodexChatThreadSummary(id: "reference", title: "Reference", updatedAt: .now)
            let meetingID = UUID.v7()
            session.draft = "Question"
            session.selectedMeetingReferenceIDs = [meetingID]
            session.selectedThreadReferences = [reference]

            session.sendDraft()
            #expect(session.draft.isEmpty)
            #expect(session.selectedMeetingReferenceIDs.isEmpty)
            #expect(session.selectedThreadReferences.isEmpty)
            try #require(await pollUntil { contextProvider.requestCount == 1 })
            session.draft = nextDraft
            contextProvider.resume()
            try #require(await pollUntil { !session.hasPendingGenerationWork })

            let restoresComposer = fails && nextDraft.isEmpty
            #expect(session.draft == (restoresComposer ? "Question" : nextDraft))
            #expect(session.selectedMeetingReferenceIDs == (restoresComposer ? [meetingID] : []))
            #expect(session.selectedThreadReferences == (restoresComposer ? [reference] : []))
        }

        @Test
        func failedDeferredSteerRestoresItsOriginalThreadReference() async throws {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let settings = TestCodexChatFixtures.appSettings()
            settings.currentWorkspace = Self.testWorkspace()
            let contextProvider = TestCodexChatContextProvider(error: .invalidProtocolResponse, shouldBlock: true)
            let session = CodexChatSessionModel(service: service, settings: settings, contextProvider: contextProvider)
            session.draft = "/mcp"
            session.sendDraft()
            try #require(await pollUntil { session.activeTurnID != nil })

            let reference = CodexChatThreadSummary(id: "reference", title: "Reference", updatedAt: .now)
            session.draft = "Question"
            session.selectedThreadReferences = [reference]
            session.sendDraft(mode: .steer)
            let queued = try #require(session.pendingManualInputs.first)
            session.draft = ""
            session.selectedThreadReferences = []

            await service.completeBlockedTurn()
            try #require(await pollUntil { contextProvider.requestCount == 1 })
            contextProvider.resume()
            try #require(await pollUntil { !session.hasPendingGenerationWork })

            #expect(session.errorMessage != nil)
            #expect(session.draft == "Question")
            #expect(session.selectedThreadReferences == [reference])
            #expect(session.serializedComposerText == queued.text)
        }

        @Test(arguments: [false, true])
        func pendingImagePreparationPreventsRestoringThePreviousComposer(stop: Bool) async throws {
            let service = ImageChatService(supportsImages: true)
            let settings = TestCodexChatFixtures.appSettings()
            settings.currentWorkspace = Self.testWorkspace()
            let contextProvider = TestCodexChatContextProvider(error: .invalidProtocolResponse, shouldBlock: true)
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            await session.prepare()
            session.draft = "Previous question"
            session.attachedImages = (0 ..< CodexChatSessionModel.maximumAttachedImages).map { _ in
                CodexChatImageAttachment(data: Data([1]), mimeType: "image/png")
            }
            try #require(session.canSend)
            session.sendDraft()
            try #require(await pollUntil { contextProvider.requestCount == 1 })

            // Model the interval after image import accepts the next image and before decoding completes.
            session.pendingImagePreparationCount = 1
            if stop { session.stop() }
            contextProvider.resume()
            try #require(await pollUntil { !session.hasPendingGenerationWork })
            #expect(session.draft.isEmpty)
            #expect(session.attachedImages.isEmpty)

            session.attachedImages.append(CodexChatImageAttachment(data: Data([2]), mimeType: "image/png"))
            session.pendingImagePreparationCount = 0
            #expect(session.attachedImages.count == 1)
            #expect(session.canSend)
        }

        @Test
        func standaloneThinkingHandsOffToActiveResponse() async {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let settings = AppSettings()
            settings.currentWorkspace = Self.testWorkspace()
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
            #expect(session.showsStandaloneThinking)
            await waitUntil { contextProvider.requestCount == 1 }
            #expect(session.isPreparingTurn)
            #expect(session.messages.isEmpty)
            #expect(session.showsStandaloneThinking)
            #expect(CodexChatConversationItem.build(
                from: session.conversationMessages,
                showsStandaloneThinking: session.showsStandaloneThinking
            ).count == 2)
            #expect(session.conversationMessages.last?.text == "Question")

            contextProvider.resume()
            await waitUntil { session.activeTurnID != nil }
            #expect(!session.isPreparingTurn)
            #expect(session.showsStandaloneThinking)
            let waitingItems = CodexChatConversationItem.build(
                from: session.messages,
                showsStandaloneThinking: session.showsStandaloneThinking
            )
            #expect(waitingItems.count == 2)
            if case let .message(message, _) = waitingItems.first {
                #expect(message.role == .user)
                #expect(message.text == "Question")
            } else {
                Issue.record("Expected the user message before the thinking indicator")
            }
            #expect(waitingItems.last == .thinking)

            await service.yieldBlockedEvent(.delta(itemID: "item-1", text: "Partial"))
            await waitUntil { session.messages.last?.text == "Partial" }
            #expect(!session.showsStandaloneThinking)

            await service.yieldBlockedEvent(.completed(itemID: "item-1", text: "Partial"))
            await waitUntil { session.showsStandaloneThinking }
            #expect(session.messages.last?.text == "Partial")
            #expect(session.messages.last?.isStreaming == true)

            await service.yieldBlockedEvent(.reasoningDelta(
                itemID: "reasoning-1",
                summaryIndex: 0,
                text: "More reasoning"
            ))
            await waitUntil { !session.showsStandaloneThinking }
            #expect(session.messages.last?.reasoning == "More reasoning")
            let reasoningItems = CodexChatConversationItem.build(
                from: session.messages,
                showsStandaloneThinking: session.showsStandaloneThinking
            )
            #expect(!reasoningItems.contains(.thinking))
            if case let .message(_, showsInlineActivity) = reasoningItems.last {
                #expect(!showsInlineActivity)
            } else {
                Issue.record("Expected the active response message")
            }

            await service.yieldBlockedEvent(.reasoningCompleted(itemID: "reasoning-1", text: "More reasoning"))
            await waitUntil { session.showsStandaloneThinking }

            await service.yieldBlockedEvent(.delta(itemID: "item-2", text: "Next"))
            await waitUntil { !session.showsStandaloneThinking }
            #expect(session.messages.last?.text == "Partial\n\nNext")

            session.stop()
            await waitUntil { !session.isGenerating }
            #expect(!session.showsStandaloneThinking)
        }

        @Test(arguments: [CodexChatDeliveryMode.steer, .queue])
        func repeatedManualSubmitWhilePreparingIsIgnored(mode: CodexChatDeliveryMode) async {
            let service = TestCodexChatService(mode: .complete)
            let settings = TestCodexChatFixtures.appSettings()
            settings.currentWorkspace = Self.testWorkspace()
            let contextProvider = TestCodexChatContextProvider(shouldBlock: true)
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            session.draft = "Question"
            session.deliveryMode = mode

            session.sendDraft()
            await waitUntil { contextProvider.requestCount == 1 }
            #expect(session.isPreparingTurn)

            session.sendDraft()
            #expect(session.pendingManualInputs.isEmpty)

            contextProvider.resume()
            await waitUntil { !session.isGenerating }
            #expect(await service.sentTextBlocks == [["Question"]])
            #expect(session.messages.filter { $0.role == .user }.map(\.text) == ["Question"])
        }

        @Test
        func replacementWaitsForCancelledSendCleanup() async {
            let service = TestCodexChatService(mode: .delayFirstSendIgnoringCancellation)
            let settings = AppSettings()
            settings.currentWorkspace = Self.testWorkspace()
            let contextProvider = TestCodexChatContextProvider()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            session.draft = "Old question"

            session.sendDraft()
            await waitUntilAsync { await service.isSendWaiting }
            session.stop()

            contextProvider.block()
            session.draft = "New question"
            session.sendDraft()
            #expect(session.pendingManualInputs.count == 1)
            #expect(contextProvider.requestCount == 1)
            #expect(await service.sentTextBlocks == [["Old question"]])

            await service.resumeDelayedSend()
            await waitUntilAsync { await service.returnedSendCount == 1 }
            await waitUntil { contextProvider.requestCount == 2 }

            #expect(session.isPreparingTurn)
            #expect(session.showsStandaloneThinking)
            #expect(session.draft.isEmpty)
            #expect(session.messages.isEmpty)

            session.sendDraft()
            #expect(session.pendingManualInputs.isEmpty)

            session.stop()
            contextProvider.resume()
        }

        @Test
        func completedReasoningDoesNotShowThinkingWhileResponseStreams() async {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentWorkspace = Self.testWorkspace()
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                streamingUpdateInterval: .zero
            )
            session.draft = "Question"

            session.sendDraft()
            await waitUntil { session.messages.last?.text == "Partial" }

            await service.yieldBlockedEvent(.reasoningDelta(
                itemID: "reasoning-1",
                summaryIndex: 0,
                text: "More reasoning"
            ))
            await waitUntil { session.messages.last?.reasoning == "More reasoning" }

            await service.yieldBlockedEvent(.reasoningCompleted(itemID: "reasoning-1", text: "More reasoning"))
            for _ in 0 ..< 10 {
                await Task.yield()
            }
            #expect(!session.showsStandaloneThinking)

            await service.yieldBlockedEvent(.completed(itemID: "item-1", text: "Partial"))
            await waitUntil { session.showsStandaloneThinking }

            session.stop()
            await waitUntil { !session.isGenerating }
        }

        @Test
        func completedResponseShowsThinkingDuringReconciliation() async {
            let service = TestCodexChatService(mode: .complete, delaysLoad: true)
            let settings = AppSettings()
            settings.currentWorkspace = Self.testWorkspace()
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
            #expect(session.showsStandaloneThinking)

            await service.resumeDelayedLoad()
            await waitUntil { !session.isGenerating }
            #expect(!session.showsStandaloneThinking)
        }

        private static func testWorkspace() -> WorkspaceRecord {
            WorkspaceRecord(
                id: .v7(),
                path: "/tmp/chat-thinking-presentation-tests",
                name: "Chat Thinking Presentation Tests",
                createdAt: .now,
                lastOpenedAt: .now
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
