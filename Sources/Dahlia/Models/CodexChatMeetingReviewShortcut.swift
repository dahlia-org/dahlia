import Foundation

enum CodexChatMeetingReviewShortcut {
    static func title(meetingName: String) -> String {
        L10n.chatMeetingReviewShortcutTitle(meetingName)
    }

    static func prompt(meetingID: UUID) -> String {
        L10n.chatMeetingReviewShortcutPrompt(meetingID.uuidString.lowercased())
    }
}
