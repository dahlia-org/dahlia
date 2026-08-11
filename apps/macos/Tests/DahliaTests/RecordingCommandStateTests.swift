import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct RecordingCommandStateTests {
        @Test
        func startCommandReflectsCoordinatorAvailability() {
            let disabled = RecordingCommandState(isListening: false, canStartNewMeeting: false)
            let enabled = RecordingCommandState(isListening: false, canStartNewMeeting: true)

            #expect(disabled.action == .start)
            #expect(!disabled.isEnabled)
            #expect(enabled.action == .start)
            #expect(enabled.isEnabled)
        }

        @Test
        func stopCommandRemainsEnabledDuringRecording() {
            let state = RecordingCommandState(isListening: true, canStartNewMeeting: false)

            #expect(state.action == .stop)
            #expect(state.isEnabled)
        }

        @Test
        func detailCommandOnlyControlsTheMeetingItRepresents() {
            let recordingMeetingID = UUID()

            #expect(RecordingCommandState.showsDetailCommand(
                isListening: false,
                recordingMeetingID: nil,
                currentMeetingID: nil
            ))
            #expect(RecordingCommandState.showsDetailCommand(
                isListening: true,
                recordingMeetingID: recordingMeetingID,
                currentMeetingID: recordingMeetingID
            ))
            #expect(!RecordingCommandState.showsDetailCommand(
                isListening: true,
                recordingMeetingID: recordingMeetingID,
                currentMeetingID: UUID()
            ))
        }

        @Test
        func sidebarStopOnlyAppearsWhenDetailCannotStopTheRecording() {
            let recordingMeetingID = UUID()

            #expect(!RecordingCommandState.showsSidebarStop(
                recordingMeetingID: nil,
                currentMeetingID: UUID()
            ))
            #expect(!RecordingCommandState.showsSidebarStop(
                recordingMeetingID: recordingMeetingID,
                currentMeetingID: recordingMeetingID
            ))
            #expect(RecordingCommandState.showsSidebarStop(
                recordingMeetingID: recordingMeetingID,
                currentMeetingID: UUID()
            ))
            #expect(RecordingCommandState.showsSidebarStop(
                recordingMeetingID: recordingMeetingID,
                currentMeetingID: nil
            ))
        }

        @Test
        func recordingAlwaysHasExactlyOneMainWindowStopCommand() {
            let recordingMeetingID = UUID()

            for currentMeetingID in [recordingMeetingID, UUID(), nil] {
                let showsDetail = RecordingCommandState.showsDetailCommand(
                    isListening: true,
                    recordingMeetingID: recordingMeetingID,
                    currentMeetingID: currentMeetingID
                )
                let showsSidebar = RecordingCommandState.showsSidebarStop(
                    recordingMeetingID: recordingMeetingID,
                    currentMeetingID: currentMeetingID
                )

                #expect(showsDetail != showsSidebar)
            }
        }
    }
#endif
