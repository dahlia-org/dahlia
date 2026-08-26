import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class CodexChatCoordinator {
    private(set) var sessions: [CodexChatSessionID: CodexChatSessionModel] = [:]
    private(set) var history: [CodexChatThreadSummary] = []
    private(set) var historyCursor: String?
    private(set) var isLoadingHistory = false
    private(set) var historyError: String?
    private(set) var detachedSessionIDs: Set<CodexChatSessionID> = []
    private(set) var dockedSessionID: CodexChatSessionID
    var isDockedVisible = false

    @ObservationIgnored private let service: any CodexChatServicing
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let contextProvider: CodexChatContextProvider
    @ObservationIgnored private var historyGeneration = 0
    @ObservationIgnored var liveModeStatusDidChange: (@MainActor (Bool) -> Void)?

    init(
        service: any CodexChatServicing = CodexChatService.shared,
        settings: AppSettings = .shared
    ) {
        self.service = service
        self.settings = settings
        let contextProvider = CodexChatContextProvider()
        self.contextProvider = contextProvider
        let session = CodexChatSessionModel(
            service: service,
            settings: settings,
            contextProvider: contextProvider
        )
        dockedSessionID = session.id
        sessions[session.id] = session
        configureLiveModeHandler(for: session)
    }

    var dockedSession: CodexChatSessionModel {
        guard let session = sessions[dockedSessionID] else {
            preconditionFailure("Docked chat session must always exist")
        }
        return session
    }

    func session(for id: CodexChatSessionID) -> CodexChatSessionModel? {
        sessions[id]
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

    func activateVault(_ vaultID: UUID) {
        guard dockedSession.vaultID != vaultID else { return }
        contextProvider.update(vaultID: vaultID, meetingID: nil, projectID: nil, draftMeeting: nil, dbQueue: nil)
        let session = makeSession(vaultID: vaultID)
        replaceDockedSession(with: session, isVisible: isDockedVisible)
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

    func newDockedChat() {
        let session = makeSession()
        replaceDockedSession(with: session, isVisible: true)
        Task { await session.prepare() }
        Task { await refreshHistory() }
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

    func openHistoryThread(_ thread: CodexChatThreadSummary) async -> CodexChatSessionID {
        let vaultID = dockedSession.vaultID
        if let existing = sessions.values.first(where: {
            $0.backendThreadID == thread.id && $0.vaultID == vaultID
        }) {
            if !detachedSessionIDs.contains(existing.id) {
                replaceDockedSession(with: existing, isVisible: true)
            }
            return existing.id
        }

        let session = makeSession(
            vaultID: vaultID,
            backendThreadID: thread.id,
            title: thread.title
        )
        replaceDockedSession(with: session, isVisible: true)
        await session.restore()
        return session.id
    }

    func openHistoryThreadInDetachedWindow(_ thread: CodexChatThreadSummary) async -> CodexChatSessionID {
        let vaultID = dockedSession.vaultID
        if let existing = sessions.values.first(where: {
            $0.backendThreadID == thread.id && $0.vaultID == vaultID
        }) {
            if existing.id == dockedSessionID {
                detachedSessionIDs.insert(existing.id)
                let replacement = makeSession()
                replaceDockedSession(with: replacement, isVisible: false)
            } else {
                detachedSessionIDs.insert(existing.id)
            }
            return existing.id
        }

        let session = makeSession(
            vaultID: vaultID,
            backendThreadID: thread.id,
            title: thread.title
        )
        sessions[session.id] = session
        detachedSessionIDs.insert(session.id)
        await session.restore()
        return session.id
    }

    func updateCurrentContext(
        vaultID: UUID?,
        meetingID: UUID?,
        projectID: UUID? = nil,
        draftMeeting: DraftMeeting?,
        dbQueue: DatabaseQueue?
    ) {
        contextProvider.update(
            vaultID: vaultID,
            meetingID: meetingID,
            projectID: projectID,
            draftMeeting: draftMeeting,
            dbQueue: dbQueue
        )
    }

    func receiveFinalizedLiveTranscript(_ text: String, wasTruncated: Bool = false) {
        for session in sessions.values where session.isLiveModeEnabled {
            session.receiveFinalizedLiveTranscript(text, wasTruncated: wasTruncated)
        }
    }

    func disableLiveMode() {
        for session in sessions.values where session.isLiveModeEnabled {
            session.disableLiveMode()
        }
    }

    func refreshHistory() async {
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
            guard dockedSession.isBoundToCurrentVault,
                  let vaultID = dockedSession.vaultID else { return }
            let page = try await service.listThreads(cursor: historyCursor, vaultID: vaultID)
            guard generation == historyGeneration,
                  dockedSession.isBoundToCurrentVault,
                  dockedSession.vaultID == vaultID else { return }
            history.append(contentsOf: page.threads.filter { item in
                !history.contains(where: { $0.id == item.id })
            })
            historyCursor = page.nextCursor
        } catch {
            guard generation == historyGeneration else { return }
            historyError = error.localizedDescription
        }
    }

    private func removeSessionIfUnused(_ id: CodexChatSessionID) {
        guard id != dockedSessionID,
              !detachedSessionIDs.contains(id),
              let session = sessions.removeValue(forKey: id)
        else { return }
        let wasLive = session.isLiveModeEnabled
        session.release()
        if wasLive {
            notifyLiveModeStatusChanged()
        }
    }

    private func replaceDockedSession(
        with session: CodexChatSessionModel,
        isVisible: Bool
    ) {
        let previousID = dockedSessionID
        sessions[session.id] = session
        dockedSessionID = session.id
        isDockedVisible = isVisible
        removeSessionIfUnused(previousID)
    }

    private func makeSession(
        id: CodexChatSessionID = CodexChatSessionID(),
        vaultID: UUID? = nil,
        backendThreadID: String? = nil,
        title: String = ""
    ) -> CodexChatSessionModel {
        let session = CodexChatSessionModel(
            id: id,
            vaultID: vaultID,
            backendThreadID: backendThreadID,
            title: title,
            service: service,
            settings: settings,
            contextProvider: contextProvider
        )
        configureLiveModeHandler(for: session)
        return session
    }

    private func configureLiveModeHandler(for session: CodexChatSessionModel) {
        session.setLiveModeChangeHandler { [weak self] _ in
            self?.notifyLiveModeStatusChanged()
        }
    }

    private func notifyLiveModeStatusChanged() {
        liveModeStatusDidChange?(sessions.values.contains(where: \.isLiveModeEnabled))
    }
}
