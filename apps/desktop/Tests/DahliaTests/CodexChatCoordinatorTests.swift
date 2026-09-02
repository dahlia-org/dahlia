import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatCoordinatorTests {
        @Test
        func replacingDockedChatRemovesPreviousSession() {
            let service = CoordinatorTestCodexChatService()
            let coordinator = CodexChatCoordinator(service: service)
            let previousID = coordinator.dockedSessionID

            coordinator.newDockedChat()

            #expect(coordinator.dockedSessionID != previousID)
            #expect(coordinator.session(for: previousID) == nil)
            #expect(coordinator.sessions.count == 1)
        }

        @Test
        func dockedChatStartsHiddenAndCanBeShownAndHidden() {
            let coordinator = CodexChatCoordinator(service: CoordinatorTestCodexChatService())

            #expect(!coordinator.isDockedVisible)
            coordinator.showDocked()
            #expect(coordinator.isDockedVisible)
            coordinator.hideDocked()
            #expect(!coordinator.isDockedVisible)
        }

        @Test
        func fullScreenNewChatKeepsDockedSidebarHidden() {
            let coordinator = CodexChatCoordinator(service: CoordinatorTestCodexChatService())
            coordinator.showDocked()

            coordinator.newDockedChat(showDockedSidebar: false)

            #expect(!coordinator.isDockedVisible)
        }

        @Test
        func fullScreenHistorySelectionKeepsDockedSidebarHidden() async {
            let coordinator = CodexChatCoordinator(service: CoordinatorTestCodexChatService())
            coordinator.showDocked()

            let selectedID = await coordinator.openHistoryThread(
                Self.threadSummary(id: "full-screen-history"),
                showDockedSidebar: false
            )

            #expect(coordinator.session(for: selectedID)?.backendThreadID == "full-screen-history")
            #expect(!coordinator.isDockedVisible)
        }

        @Test
        func replacingDockedChatKeepsGeneratingSessionAndReusesItFromHistory() async throws {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentVault = Self.vault(name: "Background")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let backgroundSession = coordinator.dockedSession

            backgroundSession.draft = "Long-running question"
            backgroundSession.sendDraft()
            await waitUntil {
                await MainActor.run {
                    backgroundSession.isGenerating && backgroundSession.backendThreadID == "thread-1"
                }
            }

            coordinator.hideDocked()
            coordinator.newDockedChat()

            #expect(coordinator.session(for: backgroundSession.id) === backgroundSession)
            let reopenedID = await coordinator.openHistoryThread(Self.threadSummary(id: "thread-1"))
            #expect(reopenedID == backgroundSession.id)
            #expect(coordinator.dockedSession === backgroundSession)
            #expect(backgroundSession.isGenerating)

            backgroundSession.stop()
            await waitUntil { await MainActor.run { !backgroundSession.isGenerating } }
        }

        @Test
        func closingDetachedWindowKeepsGeneratingSessionUntilCompletion() async throws {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentVault = Self.vault(name: "Detached Background")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let backgroundSession = coordinator.dockedSession

            backgroundSession.draft = "Detached question"
            backgroundSession.sendDraft()
            await waitUntil {
                await MainActor.run {
                    backgroundSession.isGenerating && backgroundSession.backendThreadID == "thread-1"
                }
            }

            let detachedID = coordinator.popOutDocked()
            coordinator.detachedWindowClosed(sessionID: detachedID)

            #expect(coordinator.session(for: detachedID) === backgroundSession)
            await service.completeBlockedTurn()
            await waitUntil {
                await MainActor.run { coordinator.session(for: detachedID) == nil }
            }
            await waitUntil { await service.unsubscribedThreadIDs == ["thread-1"] }
        }

        @Test
        func hiddenSessionKeepsFollowUpWhenOriginalTurnFinishesDuringSteer() async throws {
            let service = CoordinatorTestCodexChatService(blocksTurn: true, delaysSteer: true)
            let settings = AppSettings()
            settings.currentVault = Self.vault(name: "Background Follow-up")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let backgroundSession = coordinator.dockedSession

            backgroundSession.draft = "Original question"
            backgroundSession.sendDraft()
            await waitUntil {
                await MainActor.run {
                    backgroundSession.isGenerating && backgroundSession.backendThreadID == "new-thread"
                }
            }

            backgroundSession.draft = "Follow-up question"
            backgroundSession.sendDraft()
            await waitUntil { await service.isSteerWaiting }
            coordinator.newDockedChat()

            await service.completeBlockedTurn()
            await waitUntil { await MainActor.run { !backgroundSession.isGenerating } }
            #expect(coordinator.session(for: backgroundSession.id) === backgroundSession)

            await service.resumeDelayedSteer()
            await waitUntil {
                await MainActor.run { coordinator.session(for: backgroundSession.id) == nil }
            }
            #expect(await service.steeredTextBlocks == [["Follow-up question"]])
            #expect(await service.sentTextBlocks == [["Original question"]])
        }

        @Test
        func hiddenStoppedSessionIsRemovedAfterStopCleanupCompletes() async throws {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentVault = Self.vault(name: "Stopped Background")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let backgroundSession = coordinator.dockedSession

            backgroundSession.draft = "Stop this question"
            backgroundSession.sendDraft()
            await waitUntil {
                await MainActor.run { backgroundSession.activeTurnID != nil }
            }

            backgroundSession.stop()
            coordinator.newDockedChat()

            await waitUntil {
                await MainActor.run { coordinator.session(for: backgroundSession.id) == nil }
            }
            #expect(await service.unsubscribedThreadIDs == ["thread-1"])
            #expect(await service.interruptCount == 1)
        }

        @Test
        func failedPreThreadHiddenSessionIsRemovedWhenQueuedInputCannotResume() async throws {
            let service = CoordinatorTestCodexChatService(delaysAndFailsThreadStart: true)
            let settings = AppSettings()
            settings.currentVault = Self.vault(name: "Failed Background")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let backgroundSession = coordinator.dockedSession

            backgroundSession.draft = "Original question"
            backgroundSession.sendDraft()
            await waitUntil { await service.isThreadStartWaiting }

            backgroundSession.draft = "Queued follow-up"
            backgroundSession.sendDraft()
            coordinator.newDockedChat()
            #expect(coordinator.session(for: backgroundSession.id) === backgroundSession)

            await service.resumeThreadStart()
            await waitUntil {
                await MainActor.run { coordinator.session(for: backgroundSession.id) == nil }
            }
            #expect(backgroundSession.backendThreadID == nil)
            #expect(await service.sentTextBlocks.isEmpty)
        }

        @Test
        func vaultSwitchStopsGeneratingSession() async {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentVault = Self.vault(name: "Old Background")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let backgroundSession = coordinator.dockedSession

            backgroundSession.draft = "Old vault question"
            backgroundSession.sendDraft()
            await waitUntil {
                await MainActor.run {
                    backgroundSession.isGenerating && backgroundSession.backendThreadID == "thread-1"
                }
            }

            let newVault = Self.vault(name: "New Background")
            settings.currentVault = newVault
            coordinator.activateVault(newVault.id)

            await waitUntil { await MainActor.run { !backgroundSession.isGenerating } }
            #expect(coordinator.session(for: backgroundSession.id) == nil)
            #expect(await service.interruptCount == 1)
        }

        @Test
        func poppingOutDockedChatHidesSidebarAndCreatesReplacementSession() {
            let coordinator = CodexChatCoordinator(service: CoordinatorTestCodexChatService())
            let previousID = coordinator.dockedSessionID

            let poppedOutID = coordinator.popOutDocked()

            #expect(poppedOutID == previousID)
            #expect(coordinator.detachedSessionIDs.contains(previousID))
            #expect(coordinator.dockedSessionID != previousID)
            #expect(!coordinator.isDockedVisible)
        }

        @Test
        func detachedHistorySelectionStaysDetached() async {
            let service = CoordinatorTestCodexChatService()
            let coordinator = CodexChatCoordinator(service: service)
            let originalDockedID = coordinator.dockedSessionID
            let currentWindowID = coordinator.newDetachedChat()
            let thread = Self.threadSummary(id: "history-thread")

            let selectedID = await coordinator.openHistoryThreadInDetachedWindow(thread)

            #expect(selectedID != currentWindowID)
            #expect(coordinator.detachedSessionIDs.contains(selectedID))
            #expect(coordinator.session(for: selectedID)?.backendThreadID == thread.id)
            #expect(coordinator.dockedSessionID == originalDockedID)
            #expect(!coordinator.isDockedVisible)
        }

        @Test
        func replacingDetachedChatReusesWindowSessionSlot() {
            let coordinator = CodexChatCoordinator(service: CoordinatorTestCodexChatService())
            let previousID = coordinator.newDetachedChat()

            let replacementID = coordinator.newDetachedChat(replacing: previousID)

            #expect(replacementID != previousID)
            #expect(coordinator.session(for: previousID) == nil)
            #expect(coordinator.detachedSessionIDs == [replacementID])
            #expect(coordinator.sessions.count == 2)
        }

        @Test
        func closingDetachedThreadRemovesSessionAndUnsubscribes() async {
            let service = CoordinatorTestCodexChatService()
            let settings = AppSettings()
            settings.currentVault = Self.vault(name: "Lease")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
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
        func threadActivityTracksRunningAndUserWaitStates() async throws {
            let service = CoordinatorTestCodexChatService(blocksTurn: true)
            let settings = AppSettings()
            settings.currentVault = Self.vault(name: "Activity")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let session = coordinator.dockedSession

            #expect(coordinator.activity(for: "new-thread") == nil)
            session.draft = "Question"
            session.sendDraft()
            await waitUntil { await MainActor.run { coordinator.activity(for: "new-thread") == .running } }
            coordinator.newDockedChat()
            #expect(coordinator.activity(for: "new-thread") == .running)

            let userInput = try #require(Self.userInputRequest())
            await service.yieldBlockedEvent(.userInputRequested(userInput))
            await waitUntil {
                await MainActor.run { coordinator.activity(for: "new-thread") == .waitingForUser }
            }

            await service.yieldBlockedEvent(.approvalResolved(id: userInput.id))
            await waitUntil { await MainActor.run { coordinator.activity(for: "new-thread") == .running } }

            let approval = CodexChatApprovalRequest(
                id: "approval-1",
                kind: .commandExecution,
                command: "ls"
            )
            await service.yieldBlockedEvent(.approvalRequested(approval))
            await waitUntil {
                await MainActor.run { coordinator.activity(for: "new-thread") == .waitingForUser }
            }

            await service.completeBlockedTurn()
            await waitUntil { await MainActor.run { coordinator.activity(for: "new-thread") == nil } }
        }

        @Test
        func backgroundThreadAppearsWhenItsBackendThreadStartsAfterHistoryRefresh() async {
            let service = CoordinatorTestCodexChatService(
                blocksTurn: true,
                delaysThreadStart: true,
                listsStartedThread: true
            )
            let settings = AppSettings()
            settings.currentVault = Self.vault(name: "Delayed Thread")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let backgroundSession = coordinator.dockedSession

            backgroundSession.draft = "Question"
            backgroundSession.sendDraft()
            await waitUntil { await service.isThreadStartWaiting }

            coordinator.newDockedChat()
            await waitUntil {
                await MainActor.run { coordinator.history.contains { $0.id == "history-thread" } }
            }

            await service.resumeThreadStart()
            await waitUntil {
                await MainActor.run {
                    coordinator.history.contains { $0.id == "new-thread" && $0.title == "Question" }
                        && coordinator.activity(for: "new-thread") == .running
                }
            }

            await service.completeBlockedTurn()
        }

        @Test
        func currentThreadStartDoesNotRefreshHiddenHistory() async {
            let service = CoordinatorTestCodexChatService(blocksTurn: true)
            let settings = AppSettings()
            settings.currentVault = Self.vault(name: "Current Thread")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let session = coordinator.dockedSession

            session.draft = "Question"
            session.sendDraft()
            await waitUntil {
                await MainActor.run { session.activeTurnID != nil }
            }

            #expect(await service.historyRequests == 0)
            await service.completeBlockedTurn()
        }

        @Test
        func detachedThreadAppearsWhenItsBackendThreadStarts() async throws {
            let service = CoordinatorTestCodexChatService(
                blocksTurn: true,
                delaysThreadStart: true,
                listsStartedThread: true
            )
            let settings = AppSettings()
            settings.currentVault = Self.vault(name: "Detached Thread")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let sessionID = coordinator.newDetachedChat()
            let session = try #require(coordinator.session(for: sessionID))

            session.draft = "Detached question"
            session.sendDraft()
            await waitUntil { await service.isThreadStartWaiting }

            await service.resumeThreadStart()
            await waitUntil {
                await MainActor.run {
                    coordinator.history.contains { $0.id == "new-thread" && $0.title == "Detached question" }
                        && coordinator.activity(for: "new-thread") == .running
                }
            }

            await service.completeBlockedTurn()
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
            coordinator.hideDocked()
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
        func dockedAndDetachedSessionsShareLatestScreenContext() async throws {
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

            coordinator.dockedSession.draft = "First question"
            coordinator.dockedSession.sendDraft()
            await waitUntil { await MainActor.run { !coordinator.dockedSession.isGenerating } }

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

            let prompts = await service.sentTextBlocks
            #expect(prompts.allSatisfy { $0.count == 2 })
            let contexts = prompts.map { CodexChatPromptCodec.decodeTextBlocks($0).context }
            #expect(contexts.map { $0?.meetingName } == ["First draft", "Second draft", "History draft"])
        }

        @Test
        func enteringFullScreenClearsImplicitContextFromSharedSession() async {
            let service = CoordinatorTestCodexChatService()
            let settings = AppSettings()
            let vault = Self.vault(name: "Cleared Context")
            settings.currentVault = vault
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            coordinator.updateCurrentContext(
                vaultID: vault.id,
                meetingID: nil,
                draftMeeting: DraftMeeting(id: UUID.v7(), title: "Previous meeting"),
                dbQueue: nil
            )

            coordinator.dockedSession.draft = "Meeting question"
            coordinator.dockedSession.sendDraft()
            await waitUntil { await MainActor.run { !coordinator.dockedSession.isGenerating } }

            coordinator.showDocked()
            #expect(coordinator.isDockedVisible)
            coordinator.enterFullScreen(vaultID: vault.id)
            coordinator.dockedSession.draft = "Full-screen question"
            coordinator.dockedSession.sendDraft()
            await waitUntil { await MainActor.run { !coordinator.dockedSession.isGenerating } }

            let prompts = await service.sentTextBlocks
            let contextNames = prompts.map { CodexChatPromptCodec.decodeTextBlocks($0).context?.meetingName }
            #expect(contextNames == ["Previous meeting", nil])
            #expect(!coordinator.isDockedVisible)
        }

        @Test
        func liveModeStatusRemainsEnabledUntilTheLastSessionTurnsItOff() throws {
            let settings = AppSettings()
            settings.currentVault = Self.vault(name: "Live")
            let coordinator = CodexChatCoordinator(
                service: CoordinatorTestCodexChatService(),
                settings: settings
            )
            let detachedID = coordinator.newDetachedChat()
            let detachedSession = try #require(coordinator.session(for: detachedID))
            var statuses: [Bool] = []
            coordinator.liveModeStatusDidChange = { statuses.append($0) }

            coordinator.dockedSession.toggleLiveMode()
            detachedSession.toggleLiveMode()
            coordinator.dockedSession.toggleLiveMode()
            detachedSession.toggleLiveMode()

            #expect(statuses == [true, true, true, false])
        }

        private static func threadSummary(id: String) -> CodexChatThreadSummary {
            CodexChatThreadSummary(id: id, title: "History", updatedAt: .now)
        }

        private static func userInputRequest() -> CodexChatUserInputRequest? {
            CodexChatUserInputRequest(id: "input-1", params: [
                "isBlocking": .bool(true),
                "questions": .array([.object([
                    "header": .string("Answer"),
                    "id": .string("answer"),
                    "isOther": .bool(true),
                    "options": .array([.object([
                        "description": .string("Continue the chat."),
                        "label": .string("Continue"),
                    ])]),
                    "question": .string("How should the chat continue?"),
                ])]),
            ])
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
            if await pollUntil({ await predicate() }) { return }
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

        func setThreadName(threadID _: String, name _: String) async {}

        func send(
            threadID _: String,
            inputs _: [CodexAppServerInput],
            model _: String?,
            effort _: String
        ) async throws -> AsyncThrowingStream<CodexChatTurnEvent, any Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func respondToApproval(id _: String, decision _: CodexChatApprovalDecision) async {}
        func steer(threadID _: String, turnID _: String, inputs _: [CodexAppServerInput]) async throws {}
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
        private let blocksTurn: Bool
        private let delaysSteer: Bool
        private let delaysThreadStart: Bool
        private let delaysAndFailsThreadStart: Bool
        private let listsStartedThread: Bool
        private var historyRequestCount = 0
        private var didStartThread = false
        private var startedThreadName: String?
        private(set) var unsubscribedThreadIDs: [String] = []
        private(set) var sentTextBlocks: [[String]] = []
        private(set) var steeredTextBlocks: [[String]] = []
        private var blockedTurnContinuation: AsyncThrowingStream<CodexChatTurnEvent, any Error>.Continuation?
        private var delayedSteerContinuation: CheckedContinuation<Void, Never>?
        private var delayedThreadStartContinuation: CheckedContinuation<Void, Never>?

        init(
            failFirstHistoryRequest: Bool = false,
            blocksTurn: Bool = false,
            delaysSteer: Bool = false,
            delaysThreadStart: Bool = false,
            delaysAndFailsThreadStart: Bool = false,
            listsStartedThread: Bool = false
        ) {
            self.failFirstHistoryRequest = failFirstHistoryRequest
            self.blocksTurn = blocksTurn
            self.delaysSteer = delaysSteer
            self.delaysThreadStart = delaysThreadStart
            self.delaysAndFailsThreadStart = delaysAndFailsThreadStart
            self.listsStartedThread = listsStartedThread
        }

        var isSteerWaiting: Bool { delayedSteerContinuation != nil }
        var isThreadStartWaiting: Bool { delayedThreadStartContinuation != nil }
        var historyRequests: Int { historyRequestCount }

        func models(forceRefresh _: Bool) async throws -> [CodexModel] {
            [Self.model]
        }

        func listThreads(cursor _: String?, vaultID _: UUID) async throws -> CodexChatThreadPage {
            historyRequestCount += 1
            if failFirstHistoryRequest, historyRequestCount == 1 {
                throw CodexAppServerError.processExited(nil)
            }
            let threadID = listsStartedThread && didStartThread ? "new-thread" : "history-thread"
            let title = threadID == "new-thread" ? startedThreadName ?? "" : "History"
            return CodexChatThreadPage(
                threads: [CodexChatThreadSummary(id: threadID, title: title, updatedAt: .now)],
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
            if delaysThreadStart || delaysAndFailsThreadStart {
                await withCheckedContinuation { delayedThreadStartContinuation = $0 }
            }
            if delaysAndFailsThreadStart {
                throw CodexAppServerError.invalidProtocolResponse
            }
            didStartThread = true
            return CodexChatThread(id: "new-thread", title: "", messages: [], model: "default-model", reasoningEffort: effort)
        }

        func setThreadName(threadID: String, name: String) async {
            if threadID == "new-thread" {
                startedThreadName = name
            }
        }

        func send(
            threadID _: String,
            inputs: [CodexAppServerInput],
            model _: String?,
            effort _: String
        ) async throws -> AsyncThrowingStream<CodexChatTurnEvent, any Error> {
            sentTextBlocks.append(inputs.compactMap(\.textValue))
            return AsyncThrowingStream<CodexChatTurnEvent, any Error> { continuation in
                if blocksTurn {
                    continuation.yield(.started(turnID: "turn-1"))
                    continuation.yield(.delta(itemID: "item-1", text: "Partial"))
                    blockedTurnContinuation = continuation
                } else {
                    continuation.finish()
                }
            }
        }

        func respondToApproval(id _: String, decision _: CodexChatApprovalDecision) async {}
        func steer(threadID _: String, turnID _: String, inputs: [CodexAppServerInput]) async throws {
            steeredTextBlocks.append(inputs.compactMap(\.textValue))
            if delaysSteer {
                await withCheckedContinuation { delayedSteerContinuation = $0 }
            }
        }
        func interrupt(threadID _: String, turnID _: String) async {}

        func completeBlockedTurn() {
            blockedTurnContinuation?.yield(.completed(itemID: nil, text: nil))
            blockedTurnContinuation?.finish()
            blockedTurnContinuation = nil
        }

        func yieldBlockedEvent(_ event: CodexChatTurnEvent) {
            blockedTurnContinuation?.yield(event)
        }

        func resumeDelayedSteer() {
            delayedSteerContinuation?.resume()
            delayedSteerContinuation = nil
        }

        func resumeThreadStart() {
            delayedThreadStartContinuation?.resume()
            delayedThreadStartContinuation = nil
        }

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
