import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatCoordinatorTests {
        @Test(arguments: [false, true])
        func bulkSettlingSkipsBusyTargetsAndRefreshesOnce(settled: Bool) async {
            let service = CoordinatorTestCodexChatService()
            await service.rejectSettle(on: "b", busy: true)
            let coordinator = CodexChatCoordinator(service: service, settings: AppSettings())
            let targets = ["a", "b", "c"].map { Self.threadSummary(id: $0) }

            await coordinator.setSettled(targets, settled)

            #expect(await service.settleAttempts == ["a", "b", "c"])
            #expect(await service.settledIDs == (settled ? ["a", "c"] : ["a", "b", "c"]))
            #expect(await service.historyRequests == 1)
            #expect(coordinator.historyError == nil)
        }

        @Test func bulkSettlingReportsRealWriteFailuresAfterRefreshing() async {
            let service = CoordinatorTestCodexChatService()
            await service.rejectSettle(on: "b", busy: false)
            let coordinator = CodexChatCoordinator(service: service, settings: AppSettings())
            let targets = ["a", "b", "c"].map { Self.threadSummary(id: $0) }

            await coordinator.setSettled(targets, true)

            #expect(await service.settleAttempts == ["a", "b"])
            #expect(await service.settledIDs == ["a"])
            #expect(await service.historyRequests == 1)
            #expect(coordinator.historyError == PiRuntimeError.processExited(nil).localizedDescription)
        }

        @Test(arguments: ["docked", "detached"], [false, true])
        func openingACompletedThreadAcknowledgesItsResult(surface: String, fromLink: Bool) async {
            let service = CoordinatorTestCodexChatService()
            var thread = Self.threadSummary(id: "history-thread")
            thread.isUnread = true
            thread.lastResponseAt = Date(timeIntervalSince1970: 1_700_000_000)
            thread.lastItemSeq = 3
            await service.setListedSummary(thread)
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Unread Completion")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            await coordinator.refreshHistory()
            await coordinator.refreshHistory()
            #expect(coordinator.history.first?.hasUnseenCompletion == true)
            #expect(await service.acknowledgedSequences.isEmpty)

            let selectedThread = fromLink ? Self.threadSummary(id: thread.id) : thread
            if surface == "detached" {
                _ = await coordinator.openHistoryThreadInDetachedWindow(selectedThread)
            } else {
                _ = await coordinator.openHistoryThread(selectedThread)
            }
            #expect(await service.acknowledgedSequences == [3])
            #expect(coordinator.history.first?.hasUnseenCompletion == false)
            await coordinator.refreshHistory()
            #expect(coordinator.history.first?.hasUnseenCompletion == false)
            #expect(coordinator.history.first?.lastResponseAt == thread.lastResponseAt)
        }

        @Test
        func openingAnAlreadyDetachedCompletionAcknowledgesWithoutMovingIt() async {
            let service = CoordinatorTestCodexChatService()
            var thread = Self.threadSummary(id: "history-thread")
            thread.isUnread = true
            thread.lastItemSeq = 3
            await service.setListedSummary(thread)
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Detached Completion")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let dockedID = coordinator.dockedSessionID
            let detachedID = await coordinator.openHistoryThreadInDetachedWindow(thread)
            #expect(await service.acknowledgedSequences == [3])
            thread.isUnread = true
            await service.setListedSummary(thread)
            await coordinator.refreshHistory()
            #expect(coordinator.history.first?.hasUnseenCompletion == true)

            #expect(await coordinator.openHistoryThread(thread, showDockedSidebar: false) == detachedID)
            #expect(await service.acknowledgedSequences == [3, 3])
            #expect(coordinator.history.first?.hasUnseenCompletion == false)
            #expect(coordinator.dockedSessionID == dockedID)
            #expect(!coordinator.isDockedVisible)
        }

        @Test(arguments: [false, true])
        func failedRestorationOnlyAcknowledgesACompletionAfterSuccessfulRetry(detached: Bool) async {
            let service = CoordinatorTestCodexChatService()
            var thread = Self.threadSummary(id: "history-thread")
            thread.isUnread = true
            thread.lastItemSeq = 3
            await service.setListedSummary(thread)
            await service.failRestoration()
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Failed Open")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            await coordinator.refreshHistory()
            let sessionID = if detached {
                await coordinator.openHistoryThreadInDetachedWindow(thread)
            } else {
                await coordinator.openHistoryThread(thread)
            }
            #expect(await service.acknowledgedSequences.isEmpty)
            #expect(coordinator.history.first?.hasUnseenCompletion == true)
            guard let session = coordinator.session(for: sessionID) else {
                Issue.record("Missing failed session")
                return
            }
            await service.failRestoration(false)
            await coordinator.restoreSession(session)
            #expect(await service.acknowledgedSequences == [3])
            #expect(coordinator.history.first?.hasUnseenCompletion == false)
        }

        @Test
        func aSettledRunRefreshesCompletionEvenWhileTheHistoryViewIsHidden() async {
            let service = CoordinatorTestCodexChatService()
            var thread = Self.threadSummary(id: "history-thread")
            thread.lastItemSeq = 1
            await service.setListedSummary(thread)
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Background Completion")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            await coordinator.refreshHistory()
            await waitUntil { await service.isObservingThreads }

            thread.isUnread = true
            thread.lastItemSeq = 3
            thread.lastResponseAt = .now
            await service.setListedSummary(thread)
            await service.finishBackgroundRun(notify: true)
            await waitUntil { await MainActor.run { coordinator.history.first?.hasUnseenCompletion == true } }
            #expect(coordinator.history.first?.lastResponseAt == thread.lastResponseAt)
            #expect(await service.acknowledgedSequences.isEmpty)
        }

        @Test
        func aLateOpenAcknowledgementDoesNotHideANewerCompletion() async {
            let service = CoordinatorTestCodexChatService()
            var thread = Self.threadSummary(id: "history-thread")
            thread.isUnread = true
            thread.lastItemSeq = 1
            await service.setListedSummary(thread)
            await service.blockReadAcknowledgement()
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Newer Completion")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            await coordinator.refreshHistory()
            await waitUntil { await service.isObservingThreads }
            let opened = Task { await coordinator.openHistoryThread(thread) }
            await waitUntil { await service.isReadAcknowledgementWaiting }

            thread.lastItemSeq = 3
            await service.setListedSummary(thread)
            await service.finishBackgroundRun(notify: true)
            await waitUntil { await MainActor.run { coordinator.history.first?.lastItemSeq == 3 } }
            await service.releaseReadAcknowledgement()
            _ = await opened.value
            #expect(coordinator.history.first?.hasUnseenCompletion == true)
            #expect(await service.acknowledgedSequences == [1])
        }

        @Test
        func reloadingAfterABackgroundRunKeepsTheModelPickedForTheNextMessage() async {
            let service = CoordinatorTestCodexChatService()
            await service.saveInitialHistory()
            let session = CodexChatSessionModel(backendThreadID: "history-thread", service: service, settings: AppSettings())
            session.selectModel("picked-model")
            await service.finishBackgroundRun(notify: false)
            session.runtimeState = Self.settled()
            await session.synchronizeThread()
            #expect(session.messages.last?.text == "Saved result")
            #expect(session.selectedModelID == "picked-model")
        }

        @Test
        func anotherThreadsActivityNeverReloadsThisView() async {
            let service = CoordinatorTestCodexChatService()
            await service.saveInitialHistory()
            let session = CodexChatSessionModel(backendThreadID: "history-thread", service: service, settings: AppSettings())
            let settled = Self.settled()
            session.runtimeState = settled
            await session.synchronizeThread()
            #expect(session.messages.map(\.text) == ["Original"])
            // History moved on, but this thread's settled run is the one already shown: nothing reloads.
            await service.finishBackgroundRun(notify: false)
            await session.synchronizeThread()
            #expect(session.messages.map(\.text) == ["Original"])
        }

        @Test
        func staleHistoryReadCannotReplaceANewerBackgroundResult() async {
            let service = CoordinatorTestCodexChatService()
            await service.saveInitialHistory()
            let session = CodexChatSessionModel(backendThreadID: "history-thread", service: service, settings: AppSettings())
            session.runtimeState = Self.settled()
            await service.blockNextHistoryRead()
            let stale = Task { await session.synchronizeThread() }
            await waitUntil { await service.isHistoryReadWaiting }
            await service.finishBackgroundRun(notify: false)
            session.runtimeState = Self.settled()
            await session.synchronizeThread()
            #expect(session.messages.last?.text == "Saved result")
            await service.releaseHistoryRead()
            await stale.value
            #expect(session.messages.map(\.text) == ["Original", "Delegated request", "Saved result"])
        }

        private static func settled() -> CodexChatRuntimeState {
            CodexChatRuntimeState(threadID: "history-thread", accountID: "local", turnID: .v7(), approvals: [], status: "settled")
        }

        @Test(arguments: ["runtime", "docked", "detached"])
        func completedBackgroundRunRefreshesAnAlreadyLoadedSession(surface: String) async {
            let service = CoordinatorTestCodexChatService()
            await service.saveInitialHistory()
            let coordinator = CodexChatCoordinator(service: service, settings: AppSettings())
            let thread = Self.threadSummary(id: "history-thread")
            let id = await coordinator.openHistoryThread(thread)
            guard let session = coordinator.session(for: id) else {
                Issue.record("Missing loaded session")
                return
            }
            #expect(session.messages.map(\.text) == ["Original"])
            await waitUntil { await service.isObservingThreads }
            // The running snapshot has coalesced away; only the settled state arrives.
            await service.finishBackgroundRun(notify: true, accountID: session.accountID ?? "local")
            if surface == "docked" {
                #expect(await coordinator.openHistoryThread(thread) == id)
            } else if surface == "detached" {
                #expect(await coordinator.openHistoryThreadInDetachedWindow(thread) == id)
            }
            await waitUntil { await MainActor.run { session.messages.count == 3 } }
            #expect(session.messages.map(\.text) == ["Original", "Delegated request", "Saved result"])
            #expect(!session.isGenerating)
            #expect(session.errorMessage == nil)
        }

        @Test
        func workspaceSwitchWithinAccountKeepsTheSameChatAndGeneration() async {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "First")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let original = coordinator.dockedSession
            original.draft = "Continue across workspaces"
            original.sendDraft()
            await waitUntil { await MainActor.run { original.activeTurnID != nil } }
            let workspace = Self.workspace(name: "Second")
            settings.currentWorkspace = workspace
            coordinator.activateWorkspace(workspace)
            #expect(coordinator.dockedSession === original)
            #expect(original.isGenerating)
            #expect(original.canSelectScope == false)
            #expect(await service.interruptCount == 0)
            await service.completeBlockedTurn()
            await waitUntil { await MainActor.run { !original.hasPendingGenerationWork } }
            #expect(original.isBoundToCurrentAccount)
        }

        @Test
        func replacingDockedChatRemovesPreviousSession() {
            let service = CoordinatorTestCodexChatService()
            let coordinator = CodexChatCoordinator(service: service)
            let previousID = coordinator.dockedSessionID

            coordinator.showsHistory = true
            coordinator.newDockedChat()

            #expect(!coordinator.showsHistory)
            #expect(coordinator.dockedSessionID != previousID)
            #expect(coordinator.session(for: previousID) == nil)
            #expect(coordinator.sessions.count == 1)
        }

        @Test
        func sendingInNewDockedChatShowsItAndSubmitsThePrompt() async {
            let service = CoordinatorTestCodexChatService()
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Share")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let previousID = coordinator.dockedSessionID
            coordinator.showsHistory = true

            coordinator.sendInNewDockedChat("Export the summary")

            #expect(coordinator.isDockedVisible)
            #expect(!coordinator.showsHistory)
            #expect(coordinator.dockedSessionID != previousID)
            // Submitted at the click, so the context is the meeting selected then, not after models load.
            #expect(coordinator.dockedSession.isGenerating)
            await waitUntil { await !service.sentTextBlocks.isEmpty }
            #expect(await service.sentTextBlocks.first?.joined().contains("Export the summary") == true)
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
        func relatedThreadStopPausesTheDetachedSessionsQueue() async throws {
            let service = TestCodexChatService(mode: .blockBeforeOutput)
            let settings = TestCodexChatFixtures.appSettings()
            settings.currentWorkspace = Self.workspace(name: "Related Stop")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let child = coordinator.dockedSession
            child.draft = "Start"
            child.sendDraft()
            try #require(await pollUntil { child.activeTurnID != nil })
            let threadID = try #require(child.backendThreadID)
            child.draft = "Next"
            child.sendDraft(mode: .queue)
            _ = coordinator.popOutDocked()
            await coordinator.stopThread(threadID)
            let queueWasPaused = child.isQueuePaused
            if !queueWasPaused { child.stop() }
            #expect(queueWasPaused)
            try #require(await pollUntil { !child.isGenerating && !child.isTurnCleanupPending })
            #expect(child.pendingManualInputs.map(\.text) == ["Next"])
            #expect(await service.sentTextBlocks.count == 1)
            child.resumeQueue()
            try #require(await pollUntil { await service.sentTextBlocks.count == 2 })
            try #require(await pollUntil { child.activeTurnID != nil })
            await service.completeBlockedTurn()
            try #require(await pollUntil { !child.hasPendingGenerationWork })
        }

        @Test
        func relatedThreadStopKeepsTheServiceFallbackAndPausesAnyIdleQueue() async throws {
            let service = CoordinatorTestCodexChatService()
            let coordinator = CodexChatCoordinator(service: service, settings: TestCodexChatFixtures.appSettings())
            await coordinator.stopThread("not-open")
            #expect(await service.interruptedThreadIDs == ["not-open"])
            let id = await coordinator.openHistoryThread(Self.threadSummary(id: "history"))
            let session = try #require(coordinator.session(for: id))
            session.pendingManualInputs = [CodexChatManualSubmission(deliveryMode: .queue, text: "Held", images: [])]
            await coordinator.stopThread("history")
            #expect(session.isQueuePaused)
            #expect(session.pendingManualInputs.map(\.text) == ["Held"])
            #expect(await service.interruptedThreadIDs == ["not-open", "history"])
        }

        @Test
        func replacingDockedChatKeepsAPausedQueueUntilItIsRemoved() {
            let coordinator = CodexChatCoordinator(service: TestCodexChatService(mode: .block), settings: AppSettings())
            let session = coordinator.dockedSession
            let queued = CodexChatManualSubmission(deliveryMode: .queue, text: "Held", images: [])
            session.isQueuePaused = true
            session.pendingManualInputs = [queued]
            coordinator.newDockedChat()
            #expect(coordinator.session(for: session.id) === session)
            #expect(session.pendingManualInputs == [queued])
            session.removePendingInput(id: queued.id)
            #expect(coordinator.session(for: session.id) == nil)
        }

        @Test
        func replacingDockedChatKeepsGeneratingSessionAndReusesItFromHistory() async {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Background")
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
        func closingDetachedWindowKeepsGeneratingSessionUntilCompletion() async {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Detached Background")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let backgroundSession = coordinator.dockedSession

            backgroundSession.draft = "Detached question"
            backgroundSession.sendDraft()
            // Thread creation precedes stream registration; wait for the turn before completing it.
            await waitUntil { await MainActor.run { backgroundSession.activeTurnID != nil } }

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
        func hiddenSessionKeepsFollowUpWhenOriginalTurnFinishesDuringSteer() async {
            let service = CoordinatorTestCodexChatService(blocksTurn: true, delaysSteer: true)
            let settings = TestCodexChatFixtures.appSettings()
            settings.currentWorkspace = Self.workspace(name: "Background Follow-up")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let backgroundSession = coordinator.dockedSession
            backgroundSession.deliveryMode = .steer

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
        func hiddenStoppedSessionIsRemovedAfterStopCleanupCompletes() async {
            let service = TestCodexChatService(mode: .block)
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Stopped Background")
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
        func failedPreThreadHiddenSessionIsRemovedWhenQueuedInputCannotResume() async {
            let service = CoordinatorTestCodexChatService(delaysAndFailsThreadStart: true)
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Failed Background")
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
            // The sidebar checks this before switching the main area, so a detached thread leaves it alone.
            #expect(coordinator.detachedSessionID(showingThread: thread.id) == selectedID)
            #expect(coordinator.detachedSessionID(showingThread: "other-thread") == nil)
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
            settings.currentWorkspace = Self.workspace(name: "Lease")
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
            settings.currentWorkspace = Self.workspace(name: "Activity")
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
            settings.currentWorkspace = Self.workspace(name: "Delayed Thread")
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
            settings.currentWorkspace = Self.workspace(name: "Current Thread")
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
        func dockedChatsFirstReplyMarksCachedHistoryStaleUntilARefreshStarts() async {
            let service = CoordinatorTestCodexChatService(blocksTurn: true, listsStartedThread: true)
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Hidden Start")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let session = coordinator.dockedSession
            await coordinator.refreshHistory()
            #expect(coordinator.history.map(\.id) == ["history-thread"])

            session.draft = "Question"
            session.sendDraft()
            await waitUntil { await MainActor.run { session.activeTurnID != nil } }
            // Still generating: the service may not have saved the thread yet.
            #expect(!coordinator.isHistoryStale)

            // The reply finishes while no history list watches; the cached, nonempty history lacks the thread.
            await service.completeBlockedTurn()
            await waitUntil { await MainActor.run { !session.hasPendingGenerationWork } }
            #expect(coordinator.isHistoryStale)
            #expect(await service.historyRequests == 1)

            await coordinator.refreshHistory()
            #expect(coordinator.history.map(\.id) == ["new-thread"])
            #expect(!coordinator.isHistoryStale)
        }

        @Test
        func staleHistoryClearsWhenItsRefreshStillOmitsOrFailsToListTheThread() async {
            // The listing never includes the new thread (as when it is beyond the first page).
            let service = CoordinatorTestCodexChatService(blocksTurn: true)
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Unlisted")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let session = coordinator.dockedSession
            await coordinator.refreshHistory()

            session.draft = "Question"
            session.sendDraft()
            await waitUntil { await MainActor.run { session.activeTurnID != nil } }
            await service.completeBlockedTurn()
            await waitUntil { await MainActor.run { !session.hasPendingGenerationWork } }
            #expect(coordinator.isHistoryStale)

            // One catch-up refresh; its result, which still lacks the thread, must not ask for another.
            await coordinator.refreshHistory()
            #expect(coordinator.history.map(\.id) == ["history-thread"])
            #expect(!coordinator.isHistoryStale)
            #expect(await service.historyRequests == 2)
        }

        @Test
        func staleHistoryStaysClearedWhenTheCatchUpRequestFails() async {
            let service = CoordinatorTestCodexChatService(failFirstHistoryRequest: true, blocksTurn: true)
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Failed Catch-up")
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let session = coordinator.dockedSession

            session.draft = "Question"
            session.sendDraft()
            await waitUntil { await MainActor.run { session.activeTurnID != nil } }
            await service.completeBlockedTurn()
            await waitUntil { await MainActor.run { !session.hasPendingGenerationWork } }
            #expect(coordinator.isHistoryStale)

            await coordinator.refreshHistory()
            #expect(coordinator.historyError != nil)
            #expect(!coordinator.isHistoryStale)
        }

        @Test
        func detachedThreadAppearsWhenItsBackendThreadStarts() async throws {
            let service = CoordinatorTestCodexChatService(
                blocksTurn: true,
                delaysThreadStart: true,
                listsStartedThread: true
            )
            let settings = AppSettings()
            settings.currentWorkspace = Self.workspace(name: "Detached Thread")
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
        func olderRefreshCannotEraseNewerSettledHistory() async {
            let service = DelayedHistoryCodexChatService()
            let coordinator = CodexChatCoordinator(service: service, settings: AppSettings())
            let older = Task { await coordinator.refreshHistory() }
            await waitUntil { await service.hasBlockedRequest }
            await coordinator.refreshHistory()
            #expect(coordinator.settledHistory.map(\.id) == ["settled-history"])
            #expect(coordinator.settledCursor == "more-settled")

            await service.releaseBlockedRequest()
            await older.value
            #expect(coordinator.settledHistory.map(\.id) == ["settled-history"])
            #expect(coordinator.settledCursor == "more-settled")
            #expect(coordinator.settledCount == 26)
        }

        @Test
        func settledPaginationDoesNotOverlap() async {
            let service = DelayedHistoryCodexChatService(blocksFirstHistory: false)
            let coordinator = CodexChatCoordinator(service: service, settings: AppSettings())
            await coordinator.refreshHistory()
            await service.blockNextSettledRead()
            let first = Task { await coordinator.loadMoreSettled() }
            await waitUntil { await service.hasBlockedSettledRequest }
            await coordinator.loadMoreSettled()
            #expect(await service.settledRequests == 2)
            await service.releaseSettledRead()
            await first.value
            #expect(coordinator.settledCursor == nil)
            #expect(!coordinator.isLoadingSettled)
        }

        @Test
        func refreshingHistoryRetriesFailedRequest() async {
            let service = CoordinatorTestCodexChatService(failFirstHistoryRequest: true)
            let settings = AppSettings()
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let workspace = WorkspaceRecord(
                id: .v7(),
                path: "/tmp/coordinator-test-workspace",
                name: "Coordinator Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            settings.currentWorkspace = workspace
            coordinator.hideDocked()
            coordinator.activateWorkspace(workspace)

            await coordinator.refreshHistory()
            #expect(coordinator.historyError != nil)

            await coordinator.refreshHistory()
            #expect(coordinator.historyError == nil)
            #expect(coordinator.history.map(\.id) == ["history-thread"])
        }

        @Test
        func dockedAndDetachedSessionsShareLatestScreenContext() async throws {
            let service = CoordinatorTestCodexChatService()
            let settings = AppSettings()
            let workspace = Self.workspace(name: "Shared Context")
            settings.currentWorkspace = workspace
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            let firstDraft = DraftMeeting(id: UUID.v7(), title: "First draft")
            coordinator.updateCurrentContext(
                workspaceID: workspace.id,
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
                workspaceID: workspace.id,
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
                workspaceID: workspace.id,
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
            let workspace = Self.workspace(name: "Cleared Context")
            settings.currentWorkspace = workspace
            let coordinator = CodexChatCoordinator(service: service, settings: settings)
            coordinator.updateCurrentContext(
                workspaceID: workspace.id,
                meetingID: nil,
                draftMeeting: DraftMeeting(id: UUID.v7(), title: "Previous meeting"),
                dbQueue: nil
            )

            coordinator.dockedSession.draft = "Meeting question"
            coordinator.dockedSession.sendDraft()
            await waitUntil { await MainActor.run { !coordinator.dockedSession.isGenerating } }

            coordinator.showDocked()
            #expect(coordinator.isDockedVisible)
            coordinator.enterFullScreen(workspaceID: workspace.id)
            coordinator.dockedSession.draft = "Full-screen question"
            coordinator.dockedSession.sendDraft()
            await waitUntil { await MainActor.run { !coordinator.dockedSession.isGenerating } }

            let prompts = await service.sentTextBlocks
            let contextNames = prompts.map { CodexChatPromptCodec.decodeTextBlocks($0).context?.meetingName }
            #expect(contextNames == ["Previous meeting", nil])
            #expect(!coordinator.isDockedVisible)
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

        private static func workspace(name: String) -> WorkspaceRecord {
            WorkspaceRecord(
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

        private var blocksSettledRead = false
        private var settledContinuation: CheckedContinuation<CodexChatThreadPage, Never>?
        private(set) var settledRequests = 0

        init(blocksFirstHistory: Bool = true) { didBlock = !blocksFirstHistory }
        var hasBlockedSettledRequest: Bool { settledContinuation != nil }
        func blockNextSettledRead() { blocksSettledRead = true }
        func releaseSettledRead() {
            settledContinuation?.resume(returning: CodexChatThreadPage(threads: [], nextCursor: nil))
            settledContinuation = nil
        }

        var hasBlockedRequest: Bool { blockedContinuation != nil }

        func models(forceRefresh _: Bool) async throws -> [CodexModel] { [] }

        func listThreads(cursor _: String?) async throws -> CodexChatThreadPage {
            if !didBlock {
                didBlock = true
                return await withCheckedContinuation { continuation in
                    blockedContinuation = continuation
                }
            }
            return Self.page()
        }

        func listSettledThreads(cursor _: String?) async throws -> CodexChatThreadPage {
            settledRequests += 1
            if blocksSettledRead {
                blocksSettledRead = false
                return await withCheckedContinuation { settledContinuation = $0 }
            }
            return CodexChatThreadPage(
                threads: [.init(id: "settled-history", title: "Settled", updatedAt: .now, settledAt: .now)],
                nextCursor: "more-settled"
            )
        }

        func threadCounts() async throws -> (active: Int, settled: Int) { (1, 26) }

        func releaseBlockedRequest() {
            blockedContinuation?.resume(returning: CodexChatThreadPage(
                threads: [.init(id: "old-history", title: "Old account", updatedAt: .now)],
                nextCursor: nil
            ))
            blockedContinuation = nil
        }

        func loadThread(id: String) async throws -> CodexChatThread { Self.thread(id: id) }
        func resumeThread(id: String) async throws -> CodexChatThread { Self.thread(id: id) }
        func startThread(model _: String?, effort _: String, context _: CodexChatContext?) async throws -> CodexChatThread {
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

        private static func page() -> CodexChatThreadPage {
            let thread = CodexChatThreadSummary(
                id: "history",
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
        private var rejectedSettleID: String?
        private var rejectsAsBusy = false
        private(set) var settleAttempts: [String] = []
        private(set) var settledIDs: [String] = []

        func rejectSettle(on id: String, busy: Bool) {
            rejectedSettleID = id
            rejectsAsBusy = busy
        }

        func setThreadSettled(id: String, settled: Bool) async throws {
            settleAttempts.append(id)
            if id == rejectedSettleID {
                if rejectsAsBusy {
                    if settled { throw ChatThreadStore.SettleError.threadBusy }
                } else {
                    throw PiRuntimeError.processExited(nil)
                }
            }
            settledIDs.append(id)
        }

        private(set) var interruptedThreadIDs: [String] = []

        func interruptActiveTurn(threadID: String, turnID _: String?) async {
            interruptedThreadIDs.append(threadID)
        }

        private let failFirstHistoryRequest: Bool
        private let blocksTurn: Bool
        private let delaysSteer: Bool
        private let delaysThreadStart: Bool
        private let delaysAndFailsThreadStart: Bool
        private let listsStartedThread: Bool
        private var savedMessages: [CodexChatMessage]?
        private var blocksNextHistoryRead = false
        private var historyReadWaiter: CheckedContinuation<Void, Never>?
        var isHistoryReadWaiting: Bool { historyReadWaiter != nil }
        func blockNextHistoryRead() { blocksNextHistoryRead = true }
        func releaseHistoryRead() {
            historyReadWaiter?.resume()
            historyReadWaiter = nil
        }

        private var runtimeReader: AsyncStream<[CodexChatRuntimeState]>.Continuation?

        var isObservingThreads: Bool { runtimeReader != nil }

        func observeThreads() async -> AsyncStream<[CodexChatRuntimeState]> {
            let (stream, reader) = AsyncStream<[CodexChatRuntimeState]>.makeStream(bufferingPolicy: .bufferingNewest(1))
            runtimeReader = reader
            reader.yield([])
            return stream
        }

        func saveInitialHistory() { savedMessages = [CodexChatMessage(role: .user, text: "Original")] }

        func finishBackgroundRun(notify: Bool, accountID: String = "local") {
            savedMessages?.append(CodexChatMessage(role: .user, text: "Delegated request"))
            savedMessages?.append(CodexChatMessage(role: .assistant, text: "Saved result"))
            let state = CodexChatRuntimeState(threadID: "history-thread", accountID: accountID, turnID: .v7(), approvals: [], status: "settled")
            if notify { runtimeReader?.yield([state]) }
        }

        private var historyRequestCount = 0
        private var listedSummary: CodexChatThreadSummary?
        private var failsRestoration = false
        private var blocksReadAcknowledgement = false
        private var readAcknowledgementWaiter: CheckedContinuation<Void, Never>?
        private(set) var acknowledgedSequences: [Int64] = []

        func setListedSummary(_ summary: CodexChatThreadSummary) { listedSummary = summary }
        func failRestoration(_ fails: Bool = true) { failsRestoration = fails }
        func blockReadAcknowledgement() { blocksReadAcknowledgement = true }
        var isReadAcknowledgementWaiting: Bool { readAcknowledgementWaiter != nil }
        func releaseReadAcknowledgement() {
            readAcknowledgementWaiter?.resume()
            readAcknowledgementWaiter = nil
        }

        func markThreadSeen(id: String, through seq: Int64) async throws {
            acknowledgedSequences.append(seq)
            if blocksReadAcknowledgement { await withCheckedContinuation { readAcknowledgementWaiter = $0 } }
            if listedSummary?.id == id, let latestSeq = listedSummary?.lastItemSeq, latestSeq <= seq {
                listedSummary?.isUnread = false
            }
        }

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

        func listThreads(cursor _: String?) async throws -> CodexChatThreadPage {
            historyRequestCount += 1
            if failFirstHistoryRequest, historyRequestCount == 1 {
                throw PiRuntimeError.processExited(nil)
            }
            if let listedSummary { return CodexChatThreadPage(threads: [listedSummary], nextCursor: nil) }
            let threadID = listsStartedThread && didStartThread ? "new-thread" : "history-thread"
            let title = threadID == "new-thread" ? startedThreadName ?? "" : "History"
            return CodexChatThreadPage(
                threads: [CodexChatThreadSummary(id: threadID, title: title, updatedAt: .now)],
                nextCursor: nil
            )
        }

        func loadThread(id: String) async throws -> CodexChatThread {
            guard let savedMessages else { return Self.thread(id: id) }
            if blocksNextHistoryRead {
                blocksNextHistoryRead = false
                await withCheckedContinuation { historyReadWaiter = $0 }
            }
            return CodexChatThread(id: id, title: "History", messages: savedMessages, model: "default-model", reasoningEffort: "medium")
        }

        func resumeThread(id: String) async throws -> CodexChatThread {
            if failsRestoration { throw PiRuntimeError.processExited(nil) }
            var thread = try await loadThread(id: id)
            thread.lastItemSeq = listedSummary?.lastItemSeq
            return thread
        }

        func startThread(model _: String?, effort: String, context _: CodexChatContext?) async throws -> CodexChatThread {
            if delaysThreadStart || delaysAndFailsThreadStart {
                await withCheckedContinuation { delayedThreadStartContinuation = $0 }
            }
            if delaysAndFailsThreadStart {
                throw PiRuntimeError.invalidProtocolResponse
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
