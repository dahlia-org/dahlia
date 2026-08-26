import Foundation

extension CodexChatSessionModel {
    var showsMeetingReviewShortcut: Bool {
        backendThreadID == nil && messages.isEmpty
    }

    func canSendMeetingReviewShortcut(meetingID: UUID?) -> Bool {
        meetingID != nil
            && showsMeetingReviewShortcut
            && isBoundToCurrentVault
            && !isGenerating
            && !isTurnCleanupPending
    }

    func sendMeetingReviewShortcut(meetingID: UUID?) {
        guard canSendMeetingReviewShortcut(meetingID: meetingID),
              let meetingID else { return }
        usageTelemetryReporter(.aiChatPromptSubmitted)
        submit(
            CodexChatMeetingReviewShortcut.prompt(meetingID: meetingID),
            includesCurrentContext: false
        )
    }
}
