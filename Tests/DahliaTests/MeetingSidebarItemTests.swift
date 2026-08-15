import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingSidebarItemTests {
        @Test
        func displayTitleFallsBackForBlankMeetingNames() {
            #expect(item(meetingName: " \n ").displayTitle == L10n.newMeeting)
        }

        @Test
        func displayTitleTrimsMeetingNames() {
            #expect(item(meetingName: "  Weekly sync  ").displayTitle == "Weekly sync")
        }

        private func item(meetingName: String) -> MeetingSidebarItem {
            MeetingSidebarItem(
                meetingId: UUID.v7(),
                vaultId: UUID.v7(),
                projectId: nil,
                projectName: nil,
                meetingName: meetingName,
                status: .ready,
                duration: nil,
                createdAt: .now,
                calendarEventTitle: nil
            )
        }
    }
#endif
