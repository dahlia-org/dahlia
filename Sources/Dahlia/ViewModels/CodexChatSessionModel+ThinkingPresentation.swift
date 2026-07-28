extension CodexChatSessionModel {
    func publishStreamingOutput(using updateLimiter: CodexChatStreamingUpdateLimiter) {
        turnOutputGeneration &+= 1
        let wasAwaitingOutput = isAwaitingTurnOutput
        updateLimiter.submit(force: wasAwaitingOutput)
        if wasAwaitingOutput {
            isAwaitingTurnOutput = false
        }
    }
}
