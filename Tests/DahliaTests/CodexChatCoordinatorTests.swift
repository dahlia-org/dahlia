import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatCoordinatorTests {
        @Test
        func replacingFloatingChatRemovesPreviousSession() {
            let service = CoordinatorTestCodexChatService()
            let coordinator = CodexChatCoordinator(service: service)
            let previousID = coordinator.floatingSessionID

            coordinator.newFloatingChat()

            #expect(coordinator.floatingSessionID != previousID)
            #expect(coordinator.session(for: previousID) == nil)
            #expect(coordinator.sessions.count == 1)
        }

        @Test
        func detachedHistorySelectionStaysDetached() async {
            let service = CoordinatorTestCodexChatService()
            let coordinator = CodexChatCoordinator(service: service)
            let originalFloatingID = coordinator.floatingSessionID
            let currentWindowID = coordinator.newDetachedChat()
            let thread = Self.threadSummary(id: "history-thread")

            let selectedID = await coordinator.openHistoryThreadInDetachedWindow(thread)

            #expect(selectedID != currentWindowID)
            #expect(coordinator.detachedSessionIDs.contains(selectedID))
            #expect(coordinator.session(for: selectedID)?.backendThreadID == thread.id)
            #expect(coordinator.floatingSessionID == originalFloatingID)
            #expect(!coordinator.isFloatingVisible)
        }

        @Test
        func closingDetachedThreadRemovesSessionAndUnsubscribes() async {
            let service = CoordinatorTestCodexChatService()
            let coordinator = CodexChatCoordinator(service: service)
            let selectedID = await coordinator.openHistoryThreadInDetachedWindow(Self.threadSummary(id: "history-thread"))

            coordinator.detachedWindowClosed(sessionID: selectedID)
            await waitUntil { await service.unsubscribedThreadIDs == ["history-thread"] }

            #expect(coordinator.session(for: selectedID) == nil)
        }

        @Test
        func sessionLookupDoesNotCreateObservedState() {
            let coordinator = CodexChatCoordinator(service: CoordinatorTestCodexChatService())
            let sessionCount = coordinator.sessions.count

            let session = coordinator.session(for: CodexChatSessionID())

            #expect(session == nil)
            #expect(coordinator.sessions.count == sessionCount)
        }

        @Test
        func refreshingHistoryRetriesFailedRequest() async {
            let service = CoordinatorTestCodexChatService(failFirstHistoryRequest: true)
            let coordinator = CodexChatCoordinator(service: service)

            await coordinator.refreshHistory()
            #expect(coordinator.historyError != nil)

            await coordinator.refreshHistory()
            #expect(coordinator.historyError == nil)
            #expect(coordinator.history.map(\.id) == ["history-thread"])
        }

        private static func threadSummary(id: String) -> CodexChatThreadSummary {
            CodexChatThreadSummary(id: id, title: "History", updatedAt: .now)
        }

        private func waitUntil(
            _ predicate: @escaping @Sendable () async -> Bool
        ) async {
            for _ in 0 ..< 1000 {
                if await predicate() { return }
                await Task.yield()
            }
            Issue.record("Timed out waiting for coordinator state")
        }
    }

    private actor CoordinatorTestCodexChatService: CodexChatServicing {
        private let failFirstHistoryRequest: Bool
        private var historyRequestCount = 0
        private(set) var unsubscribedThreadIDs: [String] = []

        init(failFirstHistoryRequest: Bool = false) {
            self.failFirstHistoryRequest = failFirstHistoryRequest
        }

        func models(forceRefresh _: Bool) async throws -> [CodexModel] {
            [Self.model]
        }

        func listThreads(cursor _: String?) async throws -> CodexChatThreadPage {
            historyRequestCount += 1
            if failFirstHistoryRequest, historyRequestCount == 1 {
                throw CodexAppServerError.processExited(nil)
            }
            return CodexChatThreadPage(
                threads: [CodexChatThreadSummary(id: "history-thread", title: "History", updatedAt: .now)],
                nextCursor: nil
            )
        }

        func loadThread(id: String) async throws -> CodexChatThread {
            Self.thread(id: id)
        }

        func resumeThread(id: String) async throws -> CodexChatThread {
            Self.thread(id: id)
        }

        func startThread(model _: String?, effort: String) async throws -> CodexChatThread {
            CodexChatThread(id: "new-thread", title: "", messages: [], model: "default-model", reasoningEffort: effort)
        }

        func send(
            threadID _: String,
            text _: String,
            model _: String?,
            effort _: String
        ) async throws -> AsyncThrowingStream<CodexChatTurnEvent, any Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func interrupt(threadID _: String, turnID _: String) async {}

        func unsubscribe(threadID: String) async {
            unsubscribedThreadIDs.append(threadID)
        }

        private static func thread(id: String) -> CodexChatThread {
            CodexChatThread(id: id, title: "History", messages: [], model: "default-model", reasoningEffort: "medium")
        }

        private static let model = CodexModel(
            id: "default",
            model: "default-model",
            displayName: "Default",
            description: "",
            hidden: false,
            isDefault: true,
            supportedReasoningEfforts: [CodexReasoningEffortOption(reasoningEffort: "medium", description: "")],
            defaultReasoningEffort: "medium",
            inputModalities: ["text"]
        )
    }
#endif
