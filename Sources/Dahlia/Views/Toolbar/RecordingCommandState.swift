import Foundation

/// Centralizes recording command state shared by the main-window controls.
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
}
