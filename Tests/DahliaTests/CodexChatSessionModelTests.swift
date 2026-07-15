import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatSessionModelTests {
        @Test
        func firstSendCreatesThreadAndStreamsThenReconcilesRollout() async {
            let service = TestCodexChatService(mode: .complete)
            let settings = AppSettings.shared
            let oldModel = settings.codexChatModelID
            let oldEffort = settings.codexChatReasoningEffort
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
            #expect(session.title == "Question")
            #expect(await service.sentTexts == ["Question"])
        }

        @Test
        func stopKeepsPartialResponse() async {
            let service = TestCodexChatService(mode: .block)
            let session = CodexChatSessionModel(
                modelID: "default-model",
                effort: "medium",
                service: service
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

        private func waitUntil(
            _ predicate: @MainActor () -> Bool
        ) async {
            for _ in 0 ..< 1000 {
                if predicate() { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for chat state")
        }
    }

    private actor TestCodexChatService: CodexChatServicing {
        enum Mode {
            case complete
            case block
        }

        let mode: Mode
        private(set) var sentTexts: [String] = []
        private(set) var interruptCount = 0
        private var blockedContinuation: AsyncThrowingStream<CodexChatTurnEvent, any Error>.Continuation?

        init(mode: Mode) {
            self.mode = mode
        }

        func models(forceRefresh _: Bool) async throws -> [CodexModel] {
            [Self.model]
        }

        func listThreads(cursor _: String?) async throws -> CodexChatThreadPage {
            CodexChatThreadPage(threads: [], nextCursor: nil)
        }

        func loadThread(id: String) async throws -> CodexChatThread {
            CodexChatThread(
                id: id,
                title: "Question",
                messages: [
                    CodexChatMessage(role: .user, text: sentTexts.last ?? "Question"),
                    CodexChatMessage(role: .assistant, text: "Final answer"),
                ],
                model: nil,
                reasoningEffort: nil
            )
        }

        func resumeThread(id: String) async throws -> CodexChatThread {
            try await loadThread(id: id)
        }

        func startThread(model _: String?, effort: String) async throws -> CodexChatThread {
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
            case .complete:
                continuation.yield(.delta(itemID: "item-1", text: "Final "))
                continuation.yield(.completed(itemID: "item-1", text: "Final answer"))
                continuation.yield(.completed(itemID: nil, text: nil))
                continuation.finish()
            case .block:
                continuation.yield(.delta(itemID: "item-1", text: "Partial"))
                blockedContinuation = continuation
            }
            return stream
        }

        func interrupt(threadID _: String, turnID _: String) async {
            interruptCount += 1
            blockedContinuation?.yield(.interrupted)
            blockedContinuation?.finish()
            blockedContinuation = nil
        }

        func unsubscribe(threadID _: String) async {}

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
#endif
