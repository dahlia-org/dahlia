import SwiftUI

struct MenuBarCalendarEventRow: View {
    let event: CalendarEvent
    let now: Date
    let canJoinAndRecord: Bool
    let canJoin: Bool
    let canShowInCalendar: Bool
    let isAutoRecordingEnabled: Bool
    let onJoinAndRecord: () -> Void
    let onJoin: () -> Void
    let onShowInCalendar: () -> Void
    let onSetAutoRecording: (Bool) -> Void

    var body: some View {
        Menu {
            if !event.isAllDay {
                Toggle(L10n.calendarAutoRecording, systemImage: "timer", isOn: autoRecordingBinding)

                Divider()
            }

            Button(L10n.menuBarJoinMeetingWithRecording, systemImage: "record.circle", action: onJoinAndRecord)
                .disabled(!canJoinAndRecord)

            Button(L10n.menuBarJoinMeeting, systemImage: "video.fill", action: onJoin)
                .disabled(!canJoin)

            Divider()

            Button(L10n.menuBarShowEventInCalendar, systemImage: "calendar", action: onShowInCalendar)
                .disabled(!canShowInCalendar)
        } label: {
            Label {
                HStack {
                    Text(menuTitle)

                    if isAutoRecordingEnabled {
                        Image(systemName: "timer")
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(event.isAttending ? DahliaDesign.primaryTextColor : DahliaDesign.secondaryTextColor)
            } icon: {
                MenuBarCalendarParticipationIndicator(isAttending: event.isAttending)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var isOngoing: Bool {
        !event.isAllDay && event.startDate <= now && event.endDate > now
    }

    private var menuTitle: String {
        let progress = isOngoing ? " · \(L10n.menuBarInProgress)" : ""
        return "\(timeText)  \(event.resolvedMeetingTitle)\(progress)"
    }

    private var accessibilityLabel: String {
        let participation = event.isAttending ? ", \(L10n.calendarAttending)" : ""
        let autoRecording = isAutoRecordingEnabled ? ", \(L10n.calendarAutoRecordingScheduled)" : ""
        return "\(event.resolvedMeetingTitle), \(timeText), \(event.calendarName)\(participation)\(autoRecording)"
    }

    private var autoRecordingBinding: Binding<Bool> {
        Binding(
            get: { isAutoRecordingEnabled },
            set: { isEnabled in onSetAutoRecording(isEnabled) }
        )
    }

    private var timeText: String {
        if event.isAllDay {
            L10n.calendarAllDay
        } else {
            event.startDate.formatted(date: .omitted, time: .shortened)
        }
    }
}
