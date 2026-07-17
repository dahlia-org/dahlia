import Foundation

/// Centralizes recording command visibility so the same stop action is not duplicated across regions.
struct RecordingCommandState: Equatable {
    enum Action: Equatable {
        case start
        case stop
    }

    let action: Action
    let isEnabled: Bool

    init(isListening: Bool, canStartNewMeeting: Bool) {
        action = isListening ? .stop : .start
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
