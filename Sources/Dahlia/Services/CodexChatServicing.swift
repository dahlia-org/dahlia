import Foundation

protocol CodexChatServicing: Sendable {
    func models(forceRefresh: Bool) async throws -> [CodexModel]
    func listThreads(cursor: String?, vaultID: UUID) async throws -> CodexChatThreadPage
    func loadThread(id: String) async throws -> CodexChatThread
    func resumeThread(id: String, vaultID: UUID) async throws -> CodexChatThread
    func startThread(model: String?, effort: String, vaultID: UUID) async throws -> CodexChatThread
    func setThreadName(threadID: String, name: String) async
    func send(
        threadID: String,
        inputs: [CodexAppServerInput],
        model: String?,
        effort: String
    ) async throws -> AsyncThrowingStream<CodexChatTurnEvent, any Error>
    func respondToApproval(id: String, decision: CodexChatApprovalDecision) async
    func steer(threadID: String, turnID: String, inputs: [CodexAppServerInput]) async throws
    func interrupt(threadID: String, turnID: String) async
    func interruptActiveTurn(threadID: String, turnID: String?) async
    func unsubscribe(threadID: String) async
}

extension CodexChatServicing {
    func interruptActiveTurn(threadID: String, turnID: String?) async {
        guard let turnID else { return }
        await interrupt(threadID: threadID, turnID: turnID)
    }
}
