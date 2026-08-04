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
        func sidebarStopOnlyAppearsWhenPrimaryCommandReturnsToRecording() {
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
                let primaryState = RecordingCommandState(
                    isListening: true,
                    canStartNewMeeting: false,
                    recordingMeetingID: recordingMeetingID,
                    currentMeetingID: currentMeetingID
                )
                let showsSidebar = RecordingCommandState.showsSidebarStop(
                    recordingMeetingID: recordingMeetingID,
                    currentMeetingID: currentMeetingID
                )

                #expect((primaryState.action == .stop) != showsSidebar)
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
                    let stopCommandCount = [
                        placement.primaryCommandStopsRecording,
                        placement.showsSidebarStop,
                        placement.showsToolbarStop,
                    ].count(where: { $0 })
                    #expect(stopCommandCount == 1)
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
        func placementUsesPreRefreshSidebarStopBehavior() {
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

            #expect(recordingMeetingPlacement.showsSidebarRecordingPanel)
            #expect(recordingMeetingPlacement.primaryCommandStopsRecording)
            #expect(!recordingMeetingPlacement.showsSidebarStop)

            #expect(otherMeetingPlacement.showsSidebarRecordingPanel)
            #expect(!otherMeetingPlacement.primaryCommandStopsRecording)
            #expect(otherMeetingPlacement.showsSidebarStop)
            #expect(!otherMeetingPlacement.showsToolbarStop)
        }
    }
#endif
