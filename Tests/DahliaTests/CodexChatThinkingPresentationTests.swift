import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatThinkingPresentationTests {
        @Test
        func standaloneThinkingHandsOffToActiveResponse() async {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
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
            #expect(session.isPreparingTurn)
            #expect(session.messages.isEmpty)
            #expect(!session.showsStandaloneThinking)

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

        @Test
        func liveTranscriptShowsThinkingDuringContextResolution() async {
            let service = TestCodexChatService(mode: .complete)
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

            session.toggleLiveMode()
            session.receiveFinalizedLiveTranscript("Live speech")
            await waitUntil { contextProvider.requestCount == 1 }

            #expect(!session.isPreparingTurn)
            #expect(session.messages.isEmpty)
            #expect(session.showsStandaloneThinking)

            session.stop()
            await waitUntil { !session.isGenerating }
            contextProvider.resume()
        }

        @Test
        func repeatedManualSubmitWhilePreparingIsIgnored() async {
            let service = TestCodexChatService(mode: .complete)
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
            settings.currentVault = Self.testVault()
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
            #expect(!session.showsStandaloneThinking)
            #expect(session.draft == "New question")
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
            settings.currentVault = Self.testVault()
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
            #expect(session.showsStandaloneThinking)

            await service.resumeDelayedLoad()
            await waitUntil { !session.isGenerating }
            #expect(!session.showsStandaloneThinking)
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
