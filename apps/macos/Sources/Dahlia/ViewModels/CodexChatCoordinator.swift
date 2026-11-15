import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class CodexChatCoordinator {
    private(set) var sessions: [CodexChatSessionID: CodexChatSessionModel] = [:]
    private(set) var runtimeStates: [CodexChatRuntimeState] = []
    @ObservationIgnored private var threadStates: [String: CodexChatRuntimeState] = [:]
    @ObservationIgnored private var runtimeTask: Task<Void, Never>?
    private(set) var history: [CodexChatThreadSummary] = []
    private(set) var historyCursor: String?
    private(set) var isLoadingHistory = false
    private(set) var historyError: String?
    /// Set once when the docked chat's new thread finishes a turn without being listed. The coordinator does not refresh
    /// for the docked session, so a visible history list refreshes while this is set. Any refresh clears it when it starts,
    /// so a failed or still-missing result stays as it is instead of retriggering.
    private(set) var isHistoryStale = false
    private(set) var detachedSessionIDs: Set<CodexChatSessionID> = []
    private(set) var dockedSessionID: CodexChatSessionID
    var isDockedVisible = false
    /// Whether the docked chat shows its history list. A docked chat that replaces the shown one closes it.
    var showsHistory = false

    @ObservationIgnored private let service: any CodexChatServicing
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let contextProvider: CodexChatContextProvider
    @ObservationIgnored private var historyGeneration = 0
    @ObservationIgnored private var dockedAccount: WorkspaceAccountChoice
    @ObservationIgnored private var contextWorkspaceID: UUID?

    init(
        service: any CodexChatServicing = PiChatService.shared,
        settings: AppSettings = .shared
    ) {
        self.service = service
        self.settings = settings
        dockedAccount = settings.currentWorkspace.map(WorkspaceAccountChoice.init) ?? .local
        contextWorkspaceID = settings.currentWorkspace?.id
        let contextProvider = CodexChatContextProvider()
        self.contextProvider = contextProvider
        let session = CodexChatSessionModel(
            service: service,
            settings: settings,
            contextProvider: contextProvider
        )
        dockedSessionID = session.id
        sessions[session.id] = session
        configureSessionHandlers(for: session)
        runtimeTask = Task { [weak self, service] in
            let stream = await service.observeThreads()
            for await states in stream {
                guard let self else { return }
                await follow(states)
            }
        }
    }

    /// Only the thread whose run changed follows it; other views and their loaded history stay as they are.
    private func follow(_ states: [CodexChatRuntimeState]) async {
        let account = states.filter { $0.accountID == dockedSession.accountID }
        runtimeStates = account.filter { $0.status != "settled" }
        let previous = threadStates
        let current = Dictionary(account.map { ($0.threadID, $0) }, uniquingKeysWith: { first, _ in first })
        threadStates = current
        let changed = Set(previous.keys).union(current.keys).filter {
            previous[$0]?.turnID != current[$0]?.turnID || previous[$0]?.status != current[$0]?.status
        }
        for session in sessions.values {
            guard let threadID = session.backendThreadID, changed.contains(threadID) else { continue }
            session.runtimeState = current[threadID]
            await session.synchronizeThread()
        }
        let isNewThread = changed.contains { id in current[id] != nil && !history.contains { $0.id == id } }
        let settledThread = changed.contains { current[$0]?.status == "settled" && current[$0]?.isScheduled == true }
        if isNewThread || settledThread, showsHistory || isDockedVisible { await refreshHistory() }
    }

    deinit { runtimeTask?.cancel() }

    var dockedSession: CodexChatSessionModel {
        guard let session = sessions[dockedSessionID] else {
            preconditionFailure("Docked chat session must always exist")
        }
        return session
    }

    func session(for id: CodexChatSessionID) -> CodexChatSessionModel? {
        sessions[id]
    }

    func relatedThreads(parentID: String) async throws -> [CodexChatThreadSummary] {
        try await service.relatedThreads(parentThreadID: parentID)
    }

    func stopThread(_ threadID: String) async {
        await service.interruptActiveTurn(threadID: threadID, turnID: nil)
    }

    func decideRelatedApproval(_ state: CodexChatRuntimeState, id: String, decision: CodexChatApprovalDecision) async throws {
        guard state.accountID == dockedSession.accountID else { return }
        try await service.decideApproval(turnID: state.turnID, id: id, decision: decision)
    }

    func activity(for threadID: String) -> CodexChatThreadActivity? {
        if let state = runtimeStates.first(where: { $0.threadID == threadID }) {
            if state.status == "queued" { return .queued }
            return state.approvals.isEmpty ? .running : .waitingForUser
        }
        guard let session = sessions.values.first(where: {
            $0.backendThreadID == threadID && $0.accountID == dockedSession.accountID
        }) else { return nil }
        if session.pendingUserInput != nil || session.pendingApproval != nil {
            return .waitingForUser
        }
        return session.hasPendingGenerationWork ? .running : nil
    }

    func ensureDetachedSession(id: CodexChatSessionID) {
        if sessions[id] == nil {
            sessions[id] = makeSession(id: id)
        }
        detachedSessionIDs.insert(id)
    }

    func showDocked() {
        isDockedVisible = true
        Task { await dockedSession.prepare() }
        Task { await refreshHistory() }
    }

    /// Keeps the chat across Workspaces in one account; a different account gets its own history and models.
    func activateWorkspace(_ workspace: WorkspaceRecord) {
        let account = WorkspaceAccountChoice(workspace)
        let changesAccount = dockedAccount != account
        dockedAccount = account
        if contextWorkspaceID != workspace.id {
            contextProvider.update(workspaceID: workspace.id, meetingID: nil, projectID: nil, draftMeeting: nil, dbQueue: nil)
            contextWorkspaceID = workspace.id
        }
        guard changesAccount else { return }
        runtimeStates = []
        Task { await service.stopAccountRuns(except: CodexRuntimeProvider(workspace: workspace).accountKey) }
        for session in sessions.values
            where session.accountID != CodexRuntimeProvider(workspace: workspace).accountKey && session.hasPendingGenerationWork {
            session.release(stoppingRun: true)
        }
        let session = makeSession()
        replaceDockedSession(
            with: session,
            isVisible: isDockedVisible,
            preservesGeneratingPreviousSession: false
        )
        historyGeneration += 1
        history = []
        historyCursor = nil
        historyError = nil
        isLoadingHistory = false
        if isDockedVisible {
            Task { await session.prepare() }
            Task { await refreshHistory() }
        }
    }

    func hideDocked() {
        isDockedVisible = false
    }

    func enterFullScreen(workspaceID: UUID?) {
        isDockedVisible = false
        contextProvider.update(
            workspaceID: workspaceID,
            meetingID: nil,
            projectID: nil,
            draftMeeting: nil,
            dbQueue: nil
        )
    }

    func newDockedChat(showDockedSidebar: Bool = true) {
        let session = makeSession()
        replaceDockedSession(with: session, isVisible: showDockedSidebar)
        Task { await session.prepare() }
        Task { await refreshHistory() }
    }

    /// Shows a new docked chat and sends `prompt` with the selected meeting as its context.
    func sendInNewDockedChat(_ prompt: String) {
        newDockedChat()
        let session = dockedSession
        // Submit now, before models load (the composer also allows this), so the context is the meeting selected at the click.
        session.submit(prompt)
        if session.isGenerating { session.usageTelemetryReporter(.aiChatPromptSubmitted) }
    }

    func popOutDocked() -> CodexChatSessionID {
        let id = dockedSessionID
        detachedSessionIDs.insert(id)
        let replacement = makeSession()
        replaceDockedSession(with: replacement, isVisible: false)
        return id
    }

    func detachedWindowClosed(sessionID: CodexChatSessionID) {
        detachedSessionIDs.remove(sessionID)
        removeSessionIfUnused(sessionID)
    }

    func newDetachedChat() -> CodexChatSessionID {
        let session = makeSession()
        sessions[session.id] = session
        detachedSessionIDs.insert(session.id)
        Task { await session.prepare() }
        return session.id
    }

    func newDetachedChat(replacing sessionID: CodexChatSessionID) -> CodexChatSessionID {
        let replacementID = newDetachedChat()
        detachedWindowClosed(sessionID: sessionID)
        return replacementID
    }

    /// The detached window's session already showing `threadID`, if any; opening that thread brings its window forward.
    func detachedSessionID(showingThread threadID: String) -> CodexChatSessionID? {
        let accountID = dockedSession.accountID
        return sessions.values.first {
            $0.backendThreadID == threadID && $0.accountID == accountID && detachedSessionIDs.contains($0.id)
        }?.id
    }

    func openHistoryThread(
        _ thread: CodexChatThreadSummary,
        showDockedSidebar: Bool = true
    ) async -> CodexChatSessionID {
        let accountID = dockedSession.accountID
        if let schedules = try? await PiChatService.shared.scheduleService() {
            try? await Task.detached { try schedules.markSeen(thread: thread.id, account: accountID) }.value
        }
        if let existing = sessions.values.first(where: {
            $0.backendThreadID == thread.id && $0.accountID == accountID
        }) {
            if !detachedSessionIDs.contains(existing.id) {
                replaceDockedSession(with: existing, isVisible: showDockedSidebar)
            }
            await existing.synchronizeThread()
            return existing.id
        }

        let session = makeSession(
            backendThreadID: thread.id,
            title: thread.title
        )
        replaceDockedSession(with: session, isVisible: showDockedSidebar)
        await session.restore()
        return session.id
    }

    func openHistoryThreadInDetachedWindow(_ thread: CodexChatThreadSummary) async -> CodexChatSessionID {
        let accountID = dockedSession.accountID
        if let existing = sessions.values.first(where: {
            $0.backendThreadID == thread.id && $0.accountID == accountID
        }) {
            if existing.id == dockedSessionID {
                detachedSessionIDs.insert(existing.id)
                let replacement = makeSession()
                replaceDockedSession(with: replacement, isVisible: false)
            } else {
                detachedSessionIDs.insert(existing.id)
            }
            await existing.synchronizeThread()
            return existing.id
        }

        let session = makeSession(
            backendThreadID: thread.id,
            title: thread.title
        )
        sessions[session.id] = session
        detachedSessionIDs.insert(session.id)
        await session.restore()
        return session.id
    }

    func updateCurrentContext(
        workspaceID: UUID?,
        meetingID: UUID?,
        projectID: UUID? = nil,
        draftMeeting: DraftMeeting?,
        dbQueue: DatabaseQueue?
    ) {
        contextProvider.update(
            workspaceID: workspaceID,
            meetingID: meetingID,
            projectID: projectID,
            draftMeeting: draftMeeting,
            dbQueue: dbQueue
        )
    }

    func refreshHistory() async {
        isHistoryStale = false
        historyGeneration += 1
        let generation = historyGeneration
        history = []
        historyCursor = nil
        isLoadingHistory = false
        await loadMoreHistory(generation: generation)
    }

    func loadMoreHistory() async {
        await loadMoreHistory(generation: historyGeneration)
    }

    private func loadMoreHistory(generation: Int) async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        historyError = nil
        defer {
            if generation == historyGeneration {
                isLoadingHistory = false
            }
        }
        do {
            guard dockedSession.isBoundToCurrentAccount else { return }
            let accountID = dockedSession.accountID
            let page = try await service.listThreads(cursor: historyCursor)
            guard generation == historyGeneration,
                  dockedSession.isBoundToCurrentAccount,
                  dockedSession.accountID == accountID else { return }
            history.append(contentsOf: page.threads.filter { item in
                !history.contains(where: { $0.id == item.id })
            })
            history = CodexChatThreadSummary.treeOrder(history)
            historyCursor = page.nextCursor
        } catch {
            guard generation == historyGeneration else { return }
            historyError = error.localizedDescription
        }
    }

    @discardableResult
    private func removeSessionIfUnused(
        _ id: CodexChatSessionID,
        preservesGeneratingSession: Bool = true
    ) -> Bool {
        guard id != dockedSessionID,
              !detachedSessionIDs.contains(id),
              let session = sessions[id],
              !preservesGeneratingSession || (!session.hasPendingGenerationWork && !session.hasRecoverablePendingInputs)
        else { return false }
        sessions.removeValue(forKey: id)
        session.release()

        return true
    }

    private func replaceDockedSession(
        with session: CodexChatSessionModel,
        isVisible: Bool,
        preservesGeneratingPreviousSession: Bool = true
    ) {
        let previousID = dockedSessionID
        sessions[session.id] = session
        dockedSessionID = session.id
        isDockedVisible = isVisible
        showsHistory = false
        removeSessionIfUnused(
            previousID,
            preservesGeneratingSession: preservesGeneratingPreviousSession
        )
    }

    private func makeSession(
        id: CodexChatSessionID = CodexChatSessionID(),
        backendThreadID: String? = nil,
        title: String = ""
    ) -> CodexChatSessionModel {
        let session = CodexChatSessionModel(
            id: id,
            backendThreadID: backendThreadID,
            title: title,
            service: service,
            settings: settings,
            contextProvider: contextProvider
        )
        session.runtimeState = backendThreadID.flatMap { threadStates[$0] }
        configureSessionHandlers(for: session)
        return session
    }

    private func configureSessionHandlers(for session: CodexChatSessionModel) {

        session.setThreadDidStartHandler { [weak self, weak session] in
            guard let self, let session, session.id != self.dockedSessionID else { return }
            Task { await self.refreshHistory() }
        }
        session.setGenerationCompletionHandler { [weak self, weak session] in
            guard let self, let session else { return }
            // Pi saves a new thread only after its first reply, so this is when the docked chat's thread becomes listable.
            if session.id == self.dockedSessionID, session.didStartBackendThread,
               let threadID = session.backendThreadID, !self.history.contains(where: { $0.id == threadID }) {
                self.isHistoryStale = true
            }
            guard self.removeSessionIfUnused(session.id) else { return }
            Task { await self.refreshHistory() }
        }
    }

}
