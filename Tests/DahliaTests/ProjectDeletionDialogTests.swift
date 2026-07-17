import Foundation
#if canImport(Testing)
    import Testing
    @testable import Dahlia

    @MainActor
    struct ProjectDeletionDialogTests {
        @Test
        func deletesProjectWithoutMeetings() {
            let disposition = ProjectDeletionDialog.meetingDisposition(
                meetingCount: 0,
                deletesMeetings: false,
                selectedDestinationId: nil
            )

            #expect(disposition == .deleteMeetings)
        }

        @Test
        func deletesMeetingsWhenRequested() {
            let disposition = ProjectDeletionDialog.meetingDisposition(
                meetingCount: 2,
                deletesMeetings: true,
                selectedDestinationId: nil
            )

            #expect(disposition == .deleteMeetings)
        }

        @Test
        func movesMeetingsToSelectedDestination() {
            let destinationId = UUID.v7()
            let disposition = ProjectDeletionDialog.meetingDisposition(
                meetingCount: 2,
                deletesMeetings: false,
                selectedDestinationId: destinationId
            )

            #expect(disposition == .move(to: destinationId))
        }

        @Test
        func requiresDestinationBeforeMovingMeetings() {
            let disposition = ProjectDeletionDialog.meetingDisposition(
                meetingCount: 2,
                deletesMeetings: false,
                selectedDestinationId: nil
            )

            #expect(disposition == nil)
        }
    }
#endif
