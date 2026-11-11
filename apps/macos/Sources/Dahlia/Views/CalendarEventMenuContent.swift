import SwiftUI

/// Shared event options for the menu bar and the main window.
struct CalendarEventMenuContent: View {
    let event: CalendarEvent
    let canJoinAndRecord: Bool
    let canJoin: Bool
    let canShowInCalendar: Bool
    let isAutoRecordingEnabled: Bool
    let onJoinAndRecord: () -> Void
    let onJoin: () -> Void
    let onShowInCalendar: () -> Void
    let onSetAutoRecording: (Bool) -> Void

    var body: some View {
        if let joinTitle = Self.joinTitle(for: event.conferenceURI) {
            Button(joinTitle, systemImage: "video.fill", action: canJoinAndRecord ? onJoinAndRecord : onJoin)
                .disabled(!canJoin)

            Divider()
        }

        detailLabel(detailTimeText, systemImage: "clock")

        if let location = event.location {
            detailLabel(location, systemImage: "mappin.and.ellipse")
        }

        ForEach(event.meetingRoomNames, id: \.self) { roomName in
            detailLabel(roomName, systemImage: "door.left.hand.closed")
        }

        Divider()

        if !event.isAllDay {
            Toggle(L10n.calendarAutoRecording, systemImage: "timer", isOn: autoRecordingBinding)

            Divider()
        }

        Button(L10n.calendarOpenInCalendar, systemImage: "calendar", action: onShowInCalendar)
            .disabled(!canShowInCalendar)
    }

    static func joinTitle(for conferenceURI: URL?) -> String? {
        guard let conferenceURI else { return nil }
        guard let service = MeetingLinkService(conferenceURL: conferenceURI) else { return L10n.join }
        return L10n.joinMeetingService(service.displayName)
    }

    private func detailLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .disabled(true)
    }

    private var autoRecordingBinding: Binding<Bool> {
        Binding(
            get: { isAutoRecordingEnabled },
            set: { isEnabled in onSetAutoRecording(isEnabled) }
        )
    }

    private var detailTimeText: String {
        guard !event.isAllDay else { return L10n.calendarAllDay }
        let isSameDay = Calendar.autoupdatingCurrent.isDate(event.startDate, inSameDayAs: event.endDate)
        return (event.startDate ..< event.endDate).formatted(date: isSameDay ? .omitted : .abbreviated, time: .shortened)
    }

}
