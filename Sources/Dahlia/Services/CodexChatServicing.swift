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
        textBlocks: [String],
        model: String?,
        effort: String
    ) async throws -> AsyncThrowingStream<CodexChatTurnEvent, any Error>
    func interrupt(threadID: String, turnID: String) async
    func unsubscribe(threadID: String) async
}
