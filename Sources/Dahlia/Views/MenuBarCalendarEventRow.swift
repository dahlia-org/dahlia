import SwiftUI

struct MenuBarCalendarEventRow: View {
    let event: CalendarEvent
    let now: Date
    let onOpen: () -> Void
    let onJoin: (() -> Void)?

    private var isOngoing: Bool {
        !event.isAllDay && event.startDate <= now && event.endDate > now
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(event.calendarColorHex.map(Color.init(hex:)) ?? Color.accentColor)
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(event.resolvedMeetingTitle)
                                .font(.headline)
                                .lineLimit(1)

                            if isOngoing {
                                Text(L10n.menuBarInProgress)
                                    .font(.caption)
                                    .bold()
                                    .foregroundStyle(.tint)
                            }
                        }

                        Text("\(timeText) · \(event.calendarName)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.menuBarOpenEventInDahlia(event.resolvedMeetingTitle))

            if let onJoin {
                Button(L10n.join, systemImage: "video.fill", action: onJoin)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .help(L10n.join)
            }
        }
        .padding(10)
        .background(isOngoing ? Color.accentColor.opacity(0.1) : Color.clear, in: .rect(cornerRadius: 8))
    }

    private var timeText: String {
        if event.isAllDay {
            L10n.calendarAllDay
        } else {
            "\(event.startDate.formatted(date: .omitted, time: .shortened))–\(event.endDate.formatted(date: .omitted, time: .shortened))"
        }
    }
}
