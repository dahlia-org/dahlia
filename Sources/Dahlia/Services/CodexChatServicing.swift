import Foundation

protocol CodexChatServicing: Sendable {
    func models(forceRefresh: Bool) async throws -> [CodexModel]
    func listThreads(cursor: String?) async throws -> CodexChatThreadPage
    func loadThread(id: String) async throws -> CodexChatThread
    func resumeThread(id: String) async throws -> CodexChatThread
    func startThread(model: String?, effort: String) async throws -> CodexChatThread
    func send(
        threadID: String,
        text: String,
        model: String?,
        effort: String
    ) async throws -> AsyncThrowingStream<CodexChatTurnEvent, any Error>
    func interrupt(threadID: String, turnID: String) async
    func unsubscribe(threadID: String) async
}
