import Foundation

struct CodexChatSteerCompletionState {
    let submissionID: UUID
    let threadID: String
    let turnID: String
    let outputGeneration: UInt
}

extension CodexChatSessionModel {
    func completeSuccessfulSteer(
        _ input: CodexChatManualSubmission,
        context: CodexChatContext?,
        state: CodexChatSteerCompletionState
    ) async {
        guard !Task.isCancelled,
              isGenerating,
              activeSubmissionID == state.submissionID,
              activeTurnID == state.turnID,
              backendThreadID == state.threadID else { return }

        await applySuccessfulSteer(
            input,
            context: context,
            awaitsOutput: turnOutputGeneration == state.outputGeneration
        )
    }
}
