extension CodexChatSessionModel {
    func publishStreamingOutput(
        itemID: String,
        using updateLimiter: CodexChatStreamingUpdateLimiter
    ) {
        activeOutputItemIDs.insert(itemID)
        turnOutputGeneration &+= 1
        let wasAwaitingOutput = isAwaitingTurnOutput
        updateLimiter.submit(force: wasAwaitingOutput)
        if wasAwaitingOutput {
            isAwaitingTurnOutput = false
        }
    }

    func completeStreamingOutput(
        itemID: String,
        using updateLimiter: CodexChatStreamingUpdateLimiter
    ) {
        activeOutputItemIDs.remove(itemID)
        updateLimiter.submit(force: true)
        isAwaitingTurnOutput = activeOutputItemIDs.isEmpty
    }
}
