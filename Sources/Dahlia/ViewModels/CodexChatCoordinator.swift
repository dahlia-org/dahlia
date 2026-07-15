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

    init(
        service: any CodexChatServicing = CodexChatService.shared,
        settings: AppSettings = .shared
    ) {
        self.service = service
        self.settings = settings
        let session = CodexChatSessionModel(service: service, settings: settings)
        floatingSessionID = session.id
        sessions[session.id] = session
    }

    var floatingSession: CodexChatSessionModel {
        session(for: floatingSessionID)
    }

    func session(for id: CodexChatSessionID) -> CodexChatSessionModel {
        if let session = sessions[id] {
            return session
        }
        let session = CodexChatSessionModel(id: id, service: service, settings: settings)
        sessions[id] = session
        return session
    }

    func showFloating() {
        isFloatingVisible = true
        Task { await floatingSession.prepare() }
        Task { await refreshHistory() }
    }

    func hideFloating() {
        isFloatingVisible = false
    }

    func newFloatingChat() {
        let session = CodexChatSessionModel(service: service, settings: settings)
        sessions[session.id] = session
        floatingSessionID = session.id
        isFloatingVisible = true
        Task { await session.prepare() }
        Task { await refreshHistory() }
    }

    func popOutFloating() -> CodexChatSessionID {
        let id = floatingSessionID
        detachedSessionIDs.insert(id)
        let replacement = CodexChatSessionModel(service: service, settings: settings)
        sessions[replacement.id] = replacement
        floatingSessionID = replacement.id
        isFloatingVisible = false
        return id
    }

    func detachedWindowClosed(sessionID: CodexChatSessionID) {
        detachedSessionIDs.remove(sessionID)
    }

    func newDetachedChat() -> CodexChatSessionID {
        let session = CodexChatSessionModel(service: service, settings: settings)
        sessions[session.id] = session
        detachedSessionIDs.insert(session.id)
        Task { await session.prepare() }
        return session.id
    }

    func openHistoryThread(_ thread: CodexChatThreadSummary) async -> CodexChatSessionID {
        if let existing = sessions.values.first(where: { $0.backendThreadID == thread.id }) {
            if !detachedSessionIDs.contains(existing.id) {
                floatingSessionID = existing.id
                isFloatingVisible = true
            }
            return existing.id
        }

        let session = CodexChatSessionModel(
            backendThreadID: thread.id,
            title: thread.title,
            service: service,
            settings: settings
        )
        sessions[session.id] = session
        floatingSessionID = session.id
        isFloatingVisible = true
        await session.restore()
        return session.id
    }

    func refreshHistory() async {
        history = []
        historyCursor = nil
        await loadMoreHistory()
    }

    func loadMoreHistory() async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        historyError = nil
        defer { isLoadingHistory = false }
        do {
            let page = try await service.listThreads(cursor: historyCursor)
            history.append(contentsOf: page.threads.filter { item in
                !history.contains(where: { $0.id == item.id })
            })
            historyCursor = page.nextCursor
        } catch {
            historyError = error.localizedDescription
        }
    }
}
