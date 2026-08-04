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
        func primaryCommandReturnsToRecordingMeetingWhenAnotherMeetingIsVisible() {
            let recordingMeetingID = UUID()
            let state = RecordingCommandState(
                isListening: true,
                canStartNewMeeting: false,
                recordingMeetingID: recordingMeetingID,
                currentMeetingID: UUID()
            )

            #expect(state.action == .returnToRecordingMeeting)
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

        @Test
        func placementAlwaysKeepsAnImmediateStopReachable() {
            let recordingMeetingID = UUID()

            for isSidebarVisible in [false, true] {
                for currentMeetingID in [recordingMeetingID, UUID(), nil] {
                    let placement = RecordingCommandPlacement(
                        isListening: true,
                        isSidebarVisible: isSidebarVisible,
                        recordingMeetingID: recordingMeetingID,
                        currentMeetingID: currentMeetingID
                    )

                    #expect(placement.hasImmediateStop)
                    #expect(placement.showsToolbarStop == !isSidebarVisible)
                }
            }
        }

        @Test
        func placementShowsNoRecordingControlsWhileIdle() {
            let placement = RecordingCommandPlacement(
                isListening: false,
                isSidebarVisible: false,
                recordingMeetingID: nil,
                currentMeetingID: nil
            )

            #expect(!placement.hasImmediateStop)
        }

        @Test
        func placementUsesSidebarIndicatorOnlyOutsideTheRecordingMeeting() {
            let recordingMeetingID = UUID()
            let recordingMeetingPlacement = RecordingCommandPlacement(
                isListening: true,
                isSidebarVisible: true,
                recordingMeetingID: recordingMeetingID,
                currentMeetingID: recordingMeetingID
            )
            let otherMeetingPlacement = RecordingCommandPlacement(
                isListening: true,
                isSidebarVisible: true,
                recordingMeetingID: recordingMeetingID,
                currentMeetingID: UUID()
            )

            #expect(recordingMeetingPlacement.showsDetailRecordingBar)
            #expect(!recordingMeetingPlacement.showsSidebarIndicator)
            #expect(!otherMeetingPlacement.showsDetailRecordingBar)
            #expect(otherMeetingPlacement.showsSidebarIndicator)
        }
    }
#endif
