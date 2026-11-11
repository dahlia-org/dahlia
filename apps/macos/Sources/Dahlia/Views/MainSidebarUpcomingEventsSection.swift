import SwiftUI

/// The next few calendar events for a sidebar `List`, with a row that opens the full schedule.
struct MainSidebarUpcomingEventsSection: View {
    static let maximumVisibleEvents = 5
    private static let refreshInterval: TimeInterval = 300

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var calendarSourceCoordinator = CalendarSourceCoordinator.shared
    let isShowingSchedule: Bool
    /// The event whose unsaved draft meeting is open in the main area.
    let openDraftEventID: String?
    let onSelectEvent: (CalendarEvent) -> Void
    let onShowSchedule: () -> Void

    @State private var isExpanded = true
    /// Ticks on each minute so ended events leave the list and the day labels stay current while the sidebar stays open.
    @State private var now = Date.now

    var body: some View {
        MeetingSidebarListGroupLabel(
            title: L10n.upcomingEvents,
            isExpanded: isExpanded,
            onToggleExpansion: { isExpanded.toggle() }
        )
        .task(id: settings.enabledCalendarSources) {
            var nextRefresh = Date.distantPast
            while !Task.isCancelled {
                now = .now
                if now >= nextRefresh {
                    // Each refresh also rewrites the cached events, so ask no more often than the stores fetch.
                    nextRefresh = now.addingTimeInterval(Self.refreshInterval)
                    await calendarSourceCoordinator.refreshEnabledSources(settings.enabledCalendarSources)
                }
                let nextMinute = Calendar.autoupdatingCurrent.nextDate(
                    after: .now,
                    matching: DateComponents(second: 0),
                    matchingPolicy: .nextTime
                ) ?? .now.addingTimeInterval(60)
                do {
                    try await Task.sleep(for: .seconds(max(1, nextMinute.timeIntervalSinceNow)))
                } catch {
                    return
                }
            }
        }

        if isExpanded {
            ForEach(visibleEvents) { event in
                Button { onSelectEvent(event) } label: {
                    MainSidebarUpcomingEventRow(event: event, now: now, isSelected: event.id == openDraftEventID)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(event.id == openDraftEventID ? .isSelected : [])
                .listRowSeparator(.hidden)
            }

            Button(action: onShowSchedule) {
                MainSidebarNavigationLabel(
                    title: L10n.showAll,
                    systemImage: "ellipsis",
                    isSelected: isShowingSchedule
                )
                .font(.callout)
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .help(L10n.calendarScheduleTitle)
            .accessibilityAddTraits(isShowingSchedule ? .isSelected : [])
        }
    }
}

private extension MainSidebarUpcomingEventsSection {
    var visibleEvents: [CalendarEvent] {
        Array(calendarSourceCoordinator.visibleUpcomingEvents(
            for: settings.enabledCalendarSources,
            filter: settings.calendarEventFilter,
            now: now
        ).prefix(Self.maximumVisibleEvents))
    }
}

private struct MainSidebarUpcomingEventRow: View {
    let event: CalendarEvent
    let now: Date
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendarColorHex.map(Color.init(hex:)) ?? Color.accentColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            Text(event.title)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(timeText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(.rect)
        .modifier(SidebarNavigationRowModifier(isSelected: isSelected))
        .accessibilityElement(children: .combine)
    }

    /// The day, relative to `now`, for any event not today, then the time ("All day" for all-day events).
    private var timeText: String {
        let calendar = Calendar.autoupdatingCurrent
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        // An event still in progress from an earlier day counts as today's, not as a past date.
        let day = max(event.startDate, calendar.startOfDay(for: now))
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let time = if event.isAllDay {
            L10n.calendarAllDay
        } else if isToday {
            "\(start)–\(event.endDate.formatted(date: .omitted, time: .shortened))"
        } else {
            start
        }
        if isToday { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(day, inSameDayAs: tomorrow) {
            return "\(L10n.tomorrow) \(time)"
        }
        return "\(day.formatted(.dateTime.month(.defaultDigits).day())) \(time)"
    }
}
