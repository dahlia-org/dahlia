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
    let canStartRecording: Bool
    let onJoinEvent: (CalendarEvent) -> Void
    let onOpenMeetingLink: (CalendarEvent) -> Void

    @ObservedObject private var calendarAutoRecordingStore = CalendarAutoRecordingStore.shared

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
                MainSidebarUpcomingEventRow(
                    event: event,
                    now: now,
                    isSelected: event.id == openDraftEventID,
                    canStartRecording: canStartRecording,
                    isAutoRecordingEnabled: calendarAutoRecordingStore.isEnabled(for: event),
                    onSelect: { onSelectEvent(event) },
                    onJoin: { onJoinEvent(event) },
                    onOpenMeetingLink: { onOpenMeetingLink(event) },
                    onSetAutoRecording: { calendarAutoRecordingStore.setEnabled($0, for: event) }
                )
                .listRowInsets(.vertical, 1.5)
                .listRowSeparator(.hidden)
            }

            Button(action: onShowSchedule) {
                MainSidebarNavigationLabel(
                    title: L10n.showAll,
                    systemImage: "ellipsis",
                    isSelected: isShowingSchedule
                )
                .font(.dahliaBody)
            }
            .buttonStyle(.plain)
            .listRowInsets(.vertical, 1.5)
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
