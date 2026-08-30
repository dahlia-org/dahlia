import Foundation

struct CodexChatSteerCompletionState {
    let submissionID: UUID
    let threadID: String
    let turnID: String
    let includesLiveModeContext: Bool
    let liveModeGeneration: UInt
    let outputGeneration: UInt
}

extension CodexChatSessionModel {
    func completeSuccessfulSteer(
        _ input: CodexChatPendingInput,
        context: CodexChatContext?,
        state: CodexChatSteerCompletionState
    ) async {
        guard !Task.isCancelled,
              isGenerating,
              activeSubmissionID == state.submissionID,
              activeTurnID == state.turnID,
              backendThreadID == state.threadID else { return }
        if input.isLiveTranscript || input.manualSubmission?.liveModeGeneration != nil {
            guard isLiveModeEnabled,
                  liveModeGeneration == state.liveModeGeneration else { return }
        }
        if state.includesLiveModeContext {
            didSendLiveModeContext = true
        }
        await applySuccessfulSteer(
            input,
            context: context,
            awaitsOutput: turnOutputGeneration == state.outputGeneration
        )
    }
}
