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
                isShowingSettings: false,
                isListening: false,
                recordingMeetingID: nil,
                currentMeetingID: nil
            ))
            #expect(RecordingCommandState.showsDetailCommand(
                isShowingSettings: false,
                isListening: true,
                recordingMeetingID: recordingMeetingID,
                currentMeetingID: recordingMeetingID
            ))
            #expect(!RecordingCommandState.showsDetailCommand(
                isShowingSettings: false,
                isListening: true,
                recordingMeetingID: recordingMeetingID,
                currentMeetingID: UUID()
            ))
            #expect(!RecordingCommandState.showsDetailCommand(
                isShowingSettings: true,
                isListening: false,
                recordingMeetingID: nil,
                currentMeetingID: nil
            ))
        }
    }
#endif
