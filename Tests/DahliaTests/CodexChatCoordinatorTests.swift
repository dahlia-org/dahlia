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
            let settings = AppSettings()
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/coordinator-test-vault",
                name: "Coordinator Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            settings.currentVault = vault
            coordinator.activateVault(vault.id)

            await coordinator.refreshHistory()
            #expect(coordinator.historyError != nil)

            await coordinator.refreshHistory()
            #expect(coordinator.historyError == nil)
            #expect(coordinator.history.map(\.id) == ["history-thread"])
        }

        @Test
        func vaultSwitchDiscardsDelayedHistoryFromPreviousVault() async {
            let service = DelayedHistoryCodexChatService()
            let settings = AppSettings()
            let oldVault = Self.vault(name: "Old")
            let newVault = Self.vault(name: "New")
            settings.currentVault = oldVault
            let coordinator = CodexChatCoordinator(service: service, settings: settings)

            let oldRefresh = Task { await coordinator.refreshHistory() }
            await waitUntil { await service.hasBlockedRequest }
            settings.currentVault = newVault
            coordinator.activateVault(newVault.id)
            await coordinator.refreshHistory()
            await service.releaseBlockedRequest()
            await oldRefresh.value

            #expect(coordinator.history.map(\.id) == ["history-\(newVault.id.uuidString)"])
        }

        @Test
        func floatingAndDetachedSessionsShareLatestScreenContext() async throws {
            let service = CoordinatorTestCodexChatService()
            let settings = AppSettings()
            let vault = Self.vault(name: "Shared Context")
            settings.currentVault = vault
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let firstDraft = DraftMeeting(id: UUID.v7(), title: "First draft")
            coordinator.updateCurrentContext(
                vaultID: vault.id,
                meetingID: nil,
                draftMeeting: firstDraft,
                dbQueue: nil
            )

            coordinator.floatingSession.draft = "First question"
            coordinator.floatingSession.sendDraft()
            await waitUntil { await MainActor.run { !coordinator.floatingSession.isGenerating } }

            let detachedID = coordinator.newDetachedChat()
            let detachedSession = try #require(coordinator.session(for: detachedID))
            coordinator.updateCurrentContext(
                vaultID: vault.id,
                meetingID: nil,
                draftMeeting: DraftMeeting(id: UUID.v7(), title: "Second draft"),
                dbQueue: nil
            )
            detachedSession.draft = "Second question"
            detachedSession.sendDraft()
            await waitUntil { await MainActor.run { !detachedSession.isGenerating } }

            let historyID = await coordinator.openHistoryThreadInDetachedWindow(Self.threadSummary(id: "history"))
            let historySession = try #require(coordinator.session(for: historyID))
            coordinator.updateCurrentContext(
                vaultID: vault.id,
                meetingID: nil,
                draftMeeting: DraftMeeting(id: UUID.v7(), title: "History draft"),
                dbQueue: nil
            )
            historySession.draft = "History question"
            historySession.sendDraft()
            await waitUntil { await MainActor.run { !historySession.isGenerating } }

            let prompts = await service.sentTexts
            #expect(prompts.count == 3)
            let contexts = prompts.map { CodexChatPromptCodec.decode($0).context }
            #expect(contexts.map { $0?.meetingName } == ["First draft", "Second draft", "History draft"])
        }

        private static func threadSummary(id: String) -> CodexChatThreadSummary {
            CodexChatThreadSummary(id: id, title: "History", updatedAt: .now)
        }

        private static func vault(name: String) -> VaultRecord {
            VaultRecord(
                id: .v7(),
                path: "/tmp/coordinator-\(name)",
                name: name,
                createdAt: .now,
                lastOpenedAt: .now
            )
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

    private actor DelayedHistoryCodexChatService: CodexChatServicing {
        private var blockedContinuation: CheckedContinuation<CodexChatThreadPage, Never>?
        private var didBlock = false

        var hasBlockedRequest: Bool { blockedContinuation != nil }

        func models(forceRefresh _: Bool) async throws -> [CodexModel] { [] }

        func listThreads(cursor _: String?, vaultID: UUID) async throws -> CodexChatThreadPage {
            if !didBlock {
                didBlock = true
                return await withCheckedContinuation { continuation in
                    blockedContinuation = continuation
                }
            }
            return Self.page(vaultID: vaultID)
        }

        func releaseBlockedRequest() {
            blockedContinuation?.resume(returning: Self.page(vaultID: .v7()))
            blockedContinuation = nil
        }

        func loadThread(id: String) async throws -> CodexChatThread { Self.thread(id: id) }
        func resumeThread(id: String, vaultID _: UUID) async throws -> CodexChatThread { Self.thread(id: id) }
        func startThread(model _: String?, effort _: String, vaultID _: UUID) async throws -> CodexChatThread {
            Self.thread(id: "new")
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
        func unsubscribe(threadID _: String) async {}

        private static func page(vaultID: UUID) -> CodexChatThreadPage {
            let thread = CodexChatThreadSummary(
                id: "history-\(vaultID.uuidString)",
                title: "History",
                updatedAt: .now
            )
            return CodexChatThreadPage(threads: [thread], nextCursor: nil)
        }

        private static func thread(id: String) -> CodexChatThread {
            CodexChatThread(id: id, title: "", messages: [], model: nil, reasoningEffort: nil)
        }
    }

    private actor CoordinatorTestCodexChatService: CodexChatServicing {
        private let failFirstHistoryRequest: Bool
        private var historyRequestCount = 0
        private(set) var unsubscribedThreadIDs: [String] = []
        private(set) var sentTexts: [String] = []

        init(failFirstHistoryRequest: Bool = false) {
            self.failFirstHistoryRequest = failFirstHistoryRequest
        }

        func models(forceRefresh _: Bool) async throws -> [CodexModel] {
            [Self.model]
        }

        func listThreads(cursor _: String?, vaultID _: UUID) async throws -> CodexChatThreadPage {
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

        func resumeThread(id: String, vaultID _: UUID) async throws -> CodexChatThread {
            Self.thread(id: id)
        }

        func startThread(model _: String?, effort: String, vaultID _: UUID) async throws -> CodexChatThread {
            CodexChatThread(id: "new-thread", title: "", messages: [], model: "default-model", reasoningEffort: effort)
        }

        func send(
            threadID _: String,
            text: String,
            model _: String?,
            effort _: String
        ) async throws -> AsyncThrowingStream<CodexChatTurnEvent, any Error> {
            sentTexts.append(text)
            return AsyncThrowingStream<CodexChatTurnEvent, any Error> { $0.finish() }
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
