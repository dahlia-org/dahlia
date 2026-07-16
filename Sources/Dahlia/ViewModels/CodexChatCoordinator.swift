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
    private(set) var floatingSessionID: CodexChatSessionID
    var isFloatingVisible = false

    @ObservationIgnored private let service: any CodexChatServicing
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let contextProvider: CodexChatContextProvider
    @ObservationIgnored private var historyGeneration = 0

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
        floatingSessionID = session.id
        sessions[session.id] = session
    }

    var floatingSession: CodexChatSessionModel {
        guard let session = sessions[floatingSessionID] else {
            preconditionFailure("Floating chat session must always exist")
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

    func showFloating() {
        isFloatingVisible = true
        Task { await floatingSession.prepare() }
        Task { await refreshHistory() }
    }

    func activateVault(_ vaultID: UUID) {
        guard floatingSession.vaultID != vaultID else { return }
        contextProvider.update(vaultID: vaultID, meetingID: nil, draftMeeting: nil, dbQueue: nil)
        let session = makeSession(vaultID: vaultID)
        replaceFloatingSession(with: session, isVisible: isFloatingVisible)
        historyGeneration += 1
        history = []
        historyCursor = nil
        historyError = nil
        isLoadingHistory = false
        if isFloatingVisible {
            Task { await session.prepare() }
            Task { await refreshHistory() }
        }
    }

    func hideFloating() {
        isFloatingVisible = false
    }

    func newFloatingChat() {
        let session = makeSession()
        replaceFloatingSession(with: session, isVisible: true)
        Task { await session.prepare() }
        Task { await refreshHistory() }
    }

    func popOutFloating() -> CodexChatSessionID {
        let id = floatingSessionID
        detachedSessionIDs.insert(id)
        let replacement = makeSession()
        replaceFloatingSession(with: replacement, isVisible: false)
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

    func openHistoryThread(_ thread: CodexChatThreadSummary) async -> CodexChatSessionID {
        let vaultID = floatingSession.vaultID
        if let existing = sessions.values.first(where: {
            $0.backendThreadID == thread.id && $0.vaultID == vaultID
        }) {
            if !detachedSessionIDs.contains(existing.id) {
                replaceFloatingSession(with: existing, isVisible: true)
            }
            return existing.id
        }

        let session = makeSession(
            vaultID: vaultID,
            backendThreadID: thread.id,
            title: thread.title
        )
        replaceFloatingSession(with: session, isVisible: true)
        await session.restore()
        return session.id
    }

    func openHistoryThreadInDetachedWindow(_ thread: CodexChatThreadSummary) async -> CodexChatSessionID {
        let vaultID = floatingSession.vaultID
        if let existing = sessions.values.first(where: {
            $0.backendThreadID == thread.id && $0.vaultID == vaultID
        }) {
            if existing.id == floatingSessionID {
                detachedSessionIDs.insert(existing.id)
                let replacement = makeSession()
                replaceFloatingSession(with: replacement, isVisible: false)
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
        draftMeeting: DraftMeeting?,
        dbQueue: DatabaseQueue?
    ) {
        contextProvider.update(
            vaultID: vaultID,
            meetingID: meetingID,
            draftMeeting: draftMeeting,
            dbQueue: dbQueue
        )
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
            guard floatingSession.isBoundToCurrentVault,
                  let vaultID = floatingSession.vaultID else { return }
            let page = try await service.listThreads(cursor: historyCursor, vaultID: vaultID)
            guard generation == historyGeneration,
                  floatingSession.isBoundToCurrentVault,
                  floatingSession.vaultID == vaultID else { return }
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
        guard id != floatingSessionID,
              !detachedSessionIDs.contains(id),
              let session = sessions.removeValue(forKey: id)
        else { return }
        session.release()
    }

    private func replaceFloatingSession(
        with session: CodexChatSessionModel,
        isVisible: Bool
    ) {
        let previousID = floatingSessionID
        sessions[session.id] = session
        floatingSessionID = session.id
        isFloatingVisible = isVisible
        removeSessionIfUnused(previousID)
    }

    private func makeSession(
        id: CodexChatSessionID = CodexChatSessionID(),
        vaultID: UUID? = nil,
        backendThreadID: String? = nil,
        title: String = ""
    ) -> CodexChatSessionModel {
        CodexChatSessionModel(
            id: id,
            vaultID: vaultID,
            backendThreadID: backendThreadID,
            title: title,
            service: service,
            settings: settings,
            contextProvider: contextProvider
        )
    }
}
