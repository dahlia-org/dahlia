import Foundation

struct MeetingNotificationPopup: Identifiable {
    enum Action: String, Identifiable {
        case joinAndStartRecording
        case join
        case startRecording
        case close

        var id: String { rawValue }

        var title: String {
            switch self {
            case .joinAndStartRecording: L10n.joinAndStartRecording
            case .join: L10n.join
            case .startRecording: L10n.startRecording
            case .close: L10n.close
            }
        }

        var isPrimary: Bool {
            self == .joinAndStartRecording || self == .startRecording
        }

        var systemImage: String {
            switch self {
            case .joinAndStartRecording: "video.badge.waveform.fill"
            case .join: "video.fill"
            case .startRecording: "mic.and.signal.meter.fill"
            case .close: "xmark"
            }
        }

        func perform(
            for meeting: DetectedMeeting,
            onStartRecording: (DetectedMeeting) -> Void,
            onJoinMeeting: (DetectedMeeting) -> Void,
            onJoinAndStartRecording: (DetectedMeeting) -> Void
        ) {
            switch self {
            case .joinAndStartRecording:
                onJoinAndStartRecording(meeting)
            case .join:
                onJoinMeeting(meeting)
            case .startRecording:
                onStartRecording(meeting)
            case .close:
                break
            }
        }
    }

    let id: String
    let meeting: DetectedMeeting
    let title: String
    let subtitle: String?
    let body: String
    let isCalendarNotification: Bool

    var calendarDescription: String? {
        guard let description = meeting.calendarEvent?.description.nilIfBlank else { return nil }
        let boundedDescription = String(description.prefix(4000))
        let plainText = boundedDescription
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return plainText.nilIfBlank
    }

    var actions: [Action] {
        if meeting.calendarEvent?.conferenceURI != nil {
            [.joinAndStartRecording, .join, .close]
        } else {
            [.startRecording, .close]
        }
    }
}
