import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatContextDividerTests {
        @Test
        func labelsDescribeMeetingDraftAndClearedContext() {
            let meeting = CodexChatContext.meeting(
                id: UUID.v7(),
                name: "Planning",
                calendarEvent: nil
            )
            let blankDraft = CodexChatContext.meetingDraft(
                id: UUID.v7(),
                name: "",
                calendarEvent: nil
            )
            let meetingDivider = CodexChatContextDivider(context: meeting)
            let draftDivider = CodexChatContextDivider(context: blankDraft)
            let clearedDivider = CodexChatContextDivider(context: nil)

            #expect(meetingDivider.title == "Planning")
            #expect(draftDivider.title == L10n.chatMeetingDraft(L10n.newMeeting))
            #expect(clearedDivider.title == L10n.noMeetingSelected)
            #expect(meetingDivider.accessibilityLabel == L10n.chatContextChanged("Planning"))
            #expect(clearedDivider.accessibilityLabel == L10n.chatContextChanged(L10n.noMeetingSelected))
        }
    }
#endif
