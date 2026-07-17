import SwiftUI

struct MenuBarCalendarEventRow: View {
    let event: CalendarEvent
    let now: Date
    let canJoinAndRecord: Bool
    let canJoin: Bool
    let canShowInCalendar: Bool
    let onJoinAndRecord: () -> Void
    let onJoin: () -> Void
    let onShowInCalendar: () -> Void

    var body: some View {
        Menu {
            Button(L10n.menuBarJoinMeetingWithRecording, systemImage: "record.circle", action: onJoinAndRecord)
                .disabled(!canJoinAndRecord)

            Button(L10n.menuBarJoinMeeting, systemImage: "video.fill", action: onJoin)
                .disabled(!canJoin)

            Divider()

            Button(L10n.menuBarShowEventInCalendar, systemImage: "calendar", action: onShowInCalendar)
                .disabled(!canShowInCalendar)
        } label: {
            Label {
                Text(menuTitle)
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
        return "\(event.resolvedMeetingTitle), \(timeText), \(event.calendarName)\(participation)"
    }

    private var timeText: String {
        if event.isAllDay {
            L10n.calendarAllDay
        } else {
            event.startDate.formatted(date: .omitted, time: .shortened)
        }
    }
}
