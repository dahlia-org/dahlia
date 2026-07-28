import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingDeletionConfirmationTests {
        @Test
        func singleMeetingUsesNameAndPermanentDeletionWarning() {
            let request = MeetingDeletionRequest(
                meetingIds: [.v7()],
                meetingName: "Weekly sync"
            )

            #expect(request.title == L10n.deleteMeetingConfirmation("Weekly sync"))
            #expect(request.message == L10n.deleteMeetingWarning)
            #expect(request.actionTitle == L10n.delete)
        }

        @Test
        func unnamedMeetingUsesNewMeetingFallback() {
            let request = MeetingDeletionRequest(
                meetingIds: [.v7()],
                meetingName: nil
            )

            #expect(request.title == L10n.deleteMeetingConfirmation(L10n.newMeeting))
        }

        @Test
        func multipleMeetingsUseCountSpecificCopy() {
            let request = MeetingDeletionRequest(
                meetingIds: [.v7(), .v7()],
                meetingName: nil
            )

            #expect(request.title == L10n.deleteMeetingsConfirmation(2))
            #expect(request.message == L10n.deleteMeetingsWarning(2))
            #expect(request.actionTitle == L10n.deleteCount(2))
        }
    }
#endif
