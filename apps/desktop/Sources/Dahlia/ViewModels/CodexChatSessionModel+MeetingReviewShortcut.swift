extension CodexChatSessionModel {
    var showsMeetingReviewShortcut: Bool {
        backendThreadID == nil && messages.isEmpty
    }

    var canSendMeetingReviewShortcut: Bool {
        showsMeetingReviewShortcut
            && isBoundToCurrentWorkspace
            && !isGenerating
            && !isTurnCleanupPending
    }

    func sendMeetingReviewShortcut() {
        guard canSendMeetingReviewShortcut else { return }
        usageTelemetryReporter(.aiChatPromptSubmitted)
        submit(CodexChatMeetingReviewShortcut.prompt)
    }
}
