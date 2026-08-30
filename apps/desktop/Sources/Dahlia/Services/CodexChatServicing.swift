import Foundation

protocol CodexChatServicing: Sendable {
    func models(forceRefresh: Bool) async throws -> [CodexModel]
    func listThreads(cursor: String?, vaultID: UUID) async throws -> CodexChatThreadPage
    func loadThread(id: String) async throws -> CodexChatThread
    func resumeThread(id: String, vaultID: UUID) async throws -> CodexChatThread
    func startThread(model: String?, effort: String, vaultID: UUID) async throws -> CodexChatThread
    func acquireThreadLease(threadID: String) async -> UUID
    func releaseThreadLease(threadID: String, leaseID: UUID) async
    func setThreadName(threadID: String, name: String) async
    func send(
        threadID: String,
        inputs: [CodexAppServerInput],
        model: String?,
        effort: String
    ) async throws -> AsyncThrowingStream<CodexChatTurnEvent, any Error>
    func beginTurn(
        threadID: String,
        inputs: [CodexAppServerInput],
        model: String?,
        effort: String,
        approvalMethod: CodexChatApprovalMethod
    ) async throws -> CodexChatTurnHandle
    func updateApprovalMethod(
        threadID: String,
        approvalMethod: CodexChatApprovalMethod
    ) async throws -> CodexChatApprovalMethod
    func decideApproval(turnID: UUID, id: String, decision: CodexChatApprovalDecision) async throws
    func respondToUserInput(turnID: UUID, id: String, answer: String) async throws
    func stopTurn(_ turnID: UUID) async
    func respondToApproval(id: String, decision: CodexChatApprovalDecision) async
    func steer(threadID: String, turnID: String, inputs: [CodexAppServerInput]) async throws
    func interrupt(threadID: String, turnID: String) async
    func interruptActiveTurn(threadID: String, turnID: String?) async
    func unsubscribe(threadID: String) async
}

extension CodexChatServicing {
    func acquireThreadLease(threadID _: String) async -> UUID {
        UUID.v7()
    }

    func releaseThreadLease(threadID: String, leaseID _: UUID) async {
        await unsubscribe(threadID: threadID)
    }

    func beginTurn(
        threadID: String,
        inputs: [CodexAppServerInput],
        model: String?,
        effort: String,
        approvalMethod: CodexChatApprovalMethod
    ) async throws -> CodexChatTurnHandle {
        let events = try await send(
            threadID: threadID,
            inputs: inputs,
            model: model,
            effort: effort
        )
        return CodexChatTurnHandle(
            id: UUID.v7(),
            events: events,
            approvalMethod: approvalMethod
        )
    }

    func updateApprovalMethod(
        threadID _: String,
        approvalMethod: CodexChatApprovalMethod
    ) async throws -> CodexChatApprovalMethod {
        approvalMethod
    }

    func decideApproval(turnID _: UUID, id: String, decision: CodexChatApprovalDecision) async throws {
        await respondToApproval(id: id, decision: decision)
    }

    func respondToUserInput(turnID _: UUID, id _: String, answer _: String) async throws {
        throw CodexAppServerError.invalidProtocolResponse
    }

    func stopTurn(_: UUID) async {}

    func interruptActiveTurn(threadID: String, turnID: String?) async {
        guard let turnID else { return }
        await interrupt(threadID: threadID, turnID: turnID)
    }
}
