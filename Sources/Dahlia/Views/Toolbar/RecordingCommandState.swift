import Foundation

/// Centralizes recording command visibility so the same stop action is not duplicated across regions.
struct RecordingCommandState: Equatable {
    enum Action: Equatable {
        case start
        case stop
        case returnToRecordingMeeting
    }

    let action: Action
    let isEnabled: Bool

    init(
        isListening: Bool,
        canStartNewMeeting: Bool,
        recordingMeetingID: UUID? = nil,
        currentMeetingID: UUID? = nil
    ) {
        if isListening, let recordingMeetingID, recordingMeetingID != currentMeetingID {
            action = .returnToRecordingMeeting
        } else {
            action = isListening ? .stop : .start
        }
        isEnabled = isListening || canStartNewMeeting
    }

    static func showsDetailCommand(
        isListening: Bool,
        recordingMeetingID: UUID?,
        currentMeetingID: UUID?
    ) -> Bool {
        !isListening || recordingMeetingID == currentMeetingID
    }

    static func showsSidebarStop(
        recordingMeetingID: UUID?,
        currentMeetingID: UUID?
    ) -> Bool {
        guard let recordingMeetingID else { return false }
        return recordingMeetingID != currentMeetingID
    }
}

/// Pure placement policy used to keep an immediate stop command reachable as split-view columns collapse.
struct RecordingCommandPlacement: Equatable {
    let showsSidebarIndicator: Bool
    let showsDetailRecordingBar: Bool
    let showsToolbarStop: Bool

    init(
        isListening: Bool,
        isSidebarVisible: Bool,
        recordingMeetingID: UUID?,
        currentMeetingID: UUID?
    ) {
        showsSidebarIndicator = isListening && isSidebarVisible
        showsDetailRecordingBar = isListening && recordingMeetingID != nil && recordingMeetingID == currentMeetingID
        showsToolbarStop = isListening && !isSidebarVisible
    }

    var hasImmediateStop: Bool {
        showsSidebarIndicator || showsDetailRecordingBar || showsToolbarStop
    }
}
