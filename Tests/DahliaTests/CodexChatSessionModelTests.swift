import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatSessionModelTests {
        @Test
        func firstSendCreatesThreadAndStreamsThenReconcilesRollout() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            let oldModel = settings.codexChatModelID
            let oldEffort = settings.codexChatReasoningEffort
            settings.currentVault = Self.testVault()
            defer {
                settings.codexChatModelID = oldModel
                settings.codexChatReasoningEffort = oldEffort
            }
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings
            )

            #expect(session.backendThreadID == nil)
            session.draft = "Question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.backendThreadID == "thread-1")
            #expect(session.messages.map(\.text) == ["Question", "Final answer"])
            #expect(session.messages.last?.reasoning == "Considered the question")
            #expect(session.title == "Question")
            #expect(await service.sentTexts == ["Question"])
        }

        @Test
        func stopKeepsPartialResponse() async {
            let service = TestCodexChatService(mode: .block)
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
            await waitUntil { session.activeTurnID != nil }

            session.stop()
            await waitUntil { !session.isGenerating }

            #expect(session.messages.last?.text == "Partial")
            #expect(session.messages.last?.isStreaming == false)
            #expect(await service.interruptCount == 1)
        }

        @Test
        func staleRolloutDoesNotReplaceCompletedStream() async {
            let service = TestCodexChatService(mode: .staleRollout)
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
            await waitUntil { !session.isGenerating }

            #expect(session.messages.map(\.text) == ["Question", "Final answer"])
        }

        @Test
        func rolloutWithoutReasoningPreservesStreamedSummary() async {
            let service = TestCodexChatService(mode: .rolloutWithoutReasoning)
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
            await waitUntil { !session.isGenerating }

            #expect(session.messages.last?.text == "Final answer")
            #expect(session.messages.last?.reasoning == "Considered the question")
        }

        @Test
        func multipleAgentMessageItemsAreCombinedIntoOneResponse() async {
            let service = TestCodexChatService(mode: .multipleMessages)
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
            await waitUntil { !session.isGenerating }

            #expect(session.messages.map(\.text) == ["Question", "First answer\n\nSecond answer"])
            #expect(session.messages.allSatisfy { !$0.isStreaming })
        }

        @Test
        func releasedGeneratingSessionInterruptsAndUnsubscribes() async {
            let service = TestCodexChatService(mode: .block)
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
            await waitUntil { session.activeTurnID != nil }

            session.release()
            await waitUntil { !session.isGenerating }
            await waitUntilAsync { await service.interruptCount == 1 }
            await waitUntilAsync { await service.unsubscribeCount == 1 }

            #expect(await service.unsubscribedThreadIDs == ["thread-1"])
        }

        @Test
        func sessionCannotSendWhileAnotherVaultIsSelected() {
            let settings = AppSettings()
            let boundVault = Self.testVault()
            settings.currentVault = boundVault
            let session = CodexChatSessionModel(
                vaultID: boundVault.id,
                service: TestCodexChatService(mode: .complete),
                settings: settings
            )
            settings.currentVault = Self.testVault()

            session.draft = "Do not send"
            #expect(!session.canSend)
            session.sendDraft()
            #expect(session.messages.isEmpty)
        }

        @Test
        func everyTurnUsesLatestContextWithoutExposingPromptMarkup() async throws {
            let service = TestCodexChatService(mode: .staleRollout)
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let firstContext = try CodexChatContext.meeting(
                id: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                name: "First",
                calendarEvent: nil
            )
            let secondContext = try CodexChatContext.meeting(
                id: #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
                name: "Second",
                calendarEvent: nil
            )
            let contextProvider = TestCodexChatContextProvider(context: firstContext)
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )

            session.draft = "First question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }
            contextProvider.context = secondContext
            session.draft = "Second question"
            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(await service.sentTexts == [
                CodexChatPromptCodec.encode(text: "First question", context: firstContext),
                CodexChatPromptCodec.encode(text: "Second question", context: secondContext),
            ])
            #expect(session.messages.filter { $0.role == .user }.map(\.text) == [
                "First question", "Second question",
            ])
            #expect(session.messages.filter { $0.role == .user }.map(\.context) == [
                firstContext, secondContext,
            ])
        }

        @Test
        func contextFailureKeepsDraftAndDoesNotSend() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            settings.currentVault = Self.testVault()
            let contextProvider = TestCodexChatContextProvider(
                error: CodexAppServerError.invalidProtocolResponse
            )
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            session.draft = "Keep this"

            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.draft == "Keep this")
            #expect(session.messages.isEmpty)
            #expect(session.errorMessage != nil)
            #expect(await service.sentTexts.isEmpty)
        }

        @Test
        func unavailableSelectedMeetingKeepsDraftAndDoesNotSend() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings()
            let vault = Self.testVault()
            settings.currentVault = vault
            let contextProvider = CodexChatContextProvider()
            contextProvider.update(
                vaultID: vault.id,
                meetingID: UUID.v7(),
                draftMeeting: nil,
                dbQueue: nil
            )
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service,
                settings: settings,
                contextProvider: contextProvider
            )
            session.draft = "Keep selected meeting question"

            session.sendDraft()
            await waitUntil { !session.isGenerating }

            #expect(session.draft == "Keep selected meeting question")
            #expect(session.messages.isEmpty)
            #expect(session.errorMessage == L10n.chatSelectedMeetingUnavailable)
            #expect(await service.sentTexts.isEmpty)
        }

        private static func testVault() -> VaultRecord {
            VaultRecord(
                id: .v7(),
                path: "/tmp/chat-test-vault",
                name: "Chat Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
        }

        private func waitUntil(
            _ predicate: @MainActor () -> Bool
        ) async {
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

    actor TestCodexChatService: CodexChatServicing {
        enum Mode {
            case complete
            case block
            case staleRollout
            case rolloutWithoutReasoning
            case multipleMessages
        }

        let mode: Mode
        private(set) var sentTexts: [String] = []
        private(set) var interruptCount = 0
        private(set) var unsubscribedThreadIDs: [String] = []
        private var blockedContinuation: AsyncThrowingStream<CodexChatTurnEvent, any Error>.Continuation?

        var unsubscribeCount: Int {
            unsubscribedThreadIDs.count
        }

        init(mode: Mode) {
            self.mode = mode
        }

        func models(forceRefresh _: Bool) async throws -> [CodexModel] {
            [Self.model]
        }

        func listThreads(cursor _: String?, vaultID _: UUID) async throws -> CodexChatThreadPage {
            CodexChatThreadPage(threads: [], nextCursor: nil)
        }

        func loadThread(id: String) async throws -> CodexChatThread {
            let assistantMessages: [CodexChatMessage] = switch mode {
            case .complete, .block:
                [CodexChatMessage(role: .assistant, text: "Final answer", reasoning: "Considered the question")]
            case .rolloutWithoutReasoning:
                [CodexChatMessage(role: .assistant, text: "Final answer")]
            case .staleRollout, .multipleMessages:
                []
            }
            let decoded = CodexChatPromptCodec.decode(sentTexts.last ?? "Question")
            return CodexChatThread(
                id: id,
                title: "Question",
                messages: [
                    CodexChatMessage(
                        role: .user,
                        text: decoded.text,
                        context: decoded.context
                    ),
                ] + assistantMessages,
                model: nil,
                reasoningEffort: nil
            )
        }

        func resumeThread(id: String, vaultID _: UUID) async throws -> CodexChatThread {
            try await loadThread(id: id)
        }

        func startThread(model _: String?, effort: String, vaultID _: UUID) async throws -> CodexChatThread {
            CodexChatThread(
                id: "thread-1",
                title: "",
                messages: [],
                model: "default-model",
                reasoningEffort: effort
            )
        }

        func send(
            threadID _: String,
            text: String,
            model _: String?,
            effort _: String
        ) async throws -> AsyncThrowingStream<CodexChatTurnEvent, any Error> {
            sentTexts.append(text)
            let (stream, continuation) = AsyncThrowingStream<CodexChatTurnEvent, any Error>.makeStream()
            continuation.yield(.started(turnID: "turn-1"))
            switch mode {
            case .complete, .staleRollout, .rolloutWithoutReasoning:
                continuation.yield(.reasoningDelta(
                    itemID: "reasoning-1",
                    summaryIndex: 0,
                    text: "Considered the question"
                ))
                continuation.yield(.reasoningCompleted(itemID: "reasoning-1", text: "Considered the question"))
                continuation.yield(.delta(itemID: "item-1", text: "Final "))
                continuation.yield(.completed(itemID: "item-1", text: "Final answer"))
                continuation.yield(.completed(itemID: nil, text: nil))
                continuation.finish()
            case .block:
                continuation.yield(.delta(itemID: "item-1", text: "Partial"))
                blockedContinuation = continuation
            case .multipleMessages:
                continuation.yield(.delta(itemID: "item-1", text: "First "))
                continuation.yield(.completed(itemID: "item-1", text: "First answer"))
                continuation.yield(.delta(itemID: "item-2", text: "Second "))
                continuation.yield(.completed(itemID: "item-2", text: "Second answer"))
                continuation.yield(.completed(itemID: nil, text: nil))
                continuation.finish()
            }
            return stream
        }

        func interrupt(threadID _: String, turnID _: String) async {
            interruptCount += 1
            blockedContinuation?.yield(.interrupted)
            blockedContinuation?.finish()
            blockedContinuation = nil
        }

        func unsubscribe(threadID: String) async {
            unsubscribedThreadIDs.append(threadID)
        }

        private static let model = CodexModel(
            id: "default",
            model: "default-model",
            displayName: "Default",
            description: "",
            hidden: false,
            isDefault: true,
            supportedReasoningEfforts: [
                CodexReasoningEffortOption(reasoningEffort: "medium", description: ""),
            ],
            defaultReasoningEffort: "medium",
            inputModalities: ["text"]
        )
    }

    @MainActor
    private final class TestCodexChatContextProvider: CodexChatContextProviding {
        var context: CodexChatContext?
        private let error: CodexAppServerError?

        init(
            context: CodexChatContext? = nil,
            error: CodexAppServerError? = nil
        ) {
            self.context = context
            self.error = error
        }

        func currentContext(vaultID _: UUID) async throws -> CodexChatContext? {
            if let error {
                throw error
            }
            return context
        }
    }

#endif
