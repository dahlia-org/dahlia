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
        Group {
            if canJoin {
                Menu(content: menuContent, label: menuLabel, primaryAction: canJoinAndRecord ? onJoinAndRecord : onJoin)
            } else {
                Menu(content: menuContent, label: menuLabel)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private func menuContent() -> some View {
        CalendarEventMenuContent(
            event: event,
            canJoinAndRecord: canJoinAndRecord,
            canJoin: canJoin,
            canShowInCalendar: canShowInCalendar,
            isAutoRecordingEnabled: isAutoRecordingEnabled,
            onJoinAndRecord: onJoinAndRecord,
            onJoin: onJoin,
            onShowInCalendar: onShowInCalendar,
            onSetAutoRecording: onSetAutoRecording
        )
    }

    private func menuLabel() -> some View {
        Label {
            HStack {
                Text(CalendarEventTitle.attributed(menuTitle, for: event))

                if isAutoRecordingEnabled {
                    Image(systemName: "timer")
                        .accessibilityHidden(true)
                }
            }
        } icon: {
            MenuBarCalendarParticipationIndicator(isAttending: event.isAttending)
        }
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

    private var timeText: String {
        if event.isAllDay {
            L10n.calendarAllDay
        } else {
            event.startDate.formatted(date: .omitted, time: .shortened)
        }
    }
}
