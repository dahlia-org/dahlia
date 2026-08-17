import SwiftUI

/// ミーティング未選択時に表示するカレンダーの予定一覧。
struct CalendarScheduleView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var calendarSourceCoordinator = CalendarSourceCoordinator.shared
    @ObservedObject private var calendarAutoRecordingStore = CalendarAutoRecordingStore.shared
    private let googleCalendarStore = GoogleCalendarStore.shared
    private let macCalendarStore = MacCalendarStore.shared
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation

    let onSelectEvent: (CalendarEvent) -> Void
    let onJoinEvent: (CalendarEvent) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(L10n.calendarScheduleTitle)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.primary)

                content
            }
            .padding(.horizontal, 28)
            .padding(.top, DahliaDesign.detailTopPadding)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .task {
            await refreshEnabledSources()
        }
        .onChange(of: settings.enabledCalendarSourcesJSON) { _, _ in
            Task {
                await refreshEnabledSources(force: true)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            sourceStatusCards

            if visibleUpcomingEvents.isEmpty {
                emptyScheduleContent
            } else {
                eventList
            }
        }
    }

    @ViewBuilder
    private var sourceStatusCards: some View {
        if settings.isCalendarSourceEnabled(.google) {
            googleCalendarStatusCard
        }

        if settings.isCalendarSourceEnabled(.macOS) {
            macCalendarStatusCard
        }
    }

    @ViewBuilder
    private var googleCalendarStatusCard: some View {
        switch googleCalendarStore.state {
        case .unconfigured:
            statusCard(
                title: L10n.googleCalendarClientIDMissingTitle,
                message: L10n.googleCalendarClientIDMissingMessage
            )
        case .signedOut:
            statusCard(
                title: L10n.googleCalendarSignInRequiredTitle,
                message: L10n.googleCalendarScheduleSignInRequiredMessage,
                actionTitle: L10n.settings,
                action: openCalendarSettings
            )
        case .needsCalendarSelection:
            statusCard(
                title: L10n.googleCalendarSelectionRequiredTitle,
                message: L10n.googleCalendarScheduleSelectionRequiredMessage,
                actionTitle: L10n.settings,
                action: openCalendarSettings
            )
        case .loading:
            EmptyView()
        case .failed:
            statusCard(
                title: L10n.googleCalendarLoadFailedTitle,
                message: googleCalendarStore.lastErrorMessage ?? L10n.googleCalendarUnexpectedResponse,
                actionTitle: L10n.googleCalendarRetry,
                action: {
                    Task {
                        await googleCalendarStore.refreshIfNeeded(force: true)
                    }
                }
            )
        case .loaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var macCalendarStatusCard: some View {
        switch macCalendarStore.state {
        case .notDetermined:
            statusCard(
                title: L10n.macOSCalendarAccessRequiredTitle,
                message: L10n.macOSCalendarAccessRequiredMessage,
                actionTitle: L10n.macOSCalendarAllowAccess,
                action: {
                    Task {
                        await macCalendarStore.requestAccess()
                    }
                }
            )
        case .accessDenied:
            statusCard(
                title: L10n.macOSCalendarAccessDeniedTitle,
                message: L10n.macOSCalendarAccessDeniedMessage,
                actionTitle: L10n.settings,
                action: openCalendarSettings
            )
        case .needsCalendarSelection:
            statusCard(
                title: L10n.calendarSelectionRequiredTitle,
                message: L10n.calendarScheduleSelectionRequiredMessage,
                actionTitle: L10n.settings,
                action: openCalendarSettings
            )
        case .loading:
            EmptyView()
        case .failed:
            statusCard(
                title: L10n.macOSCalendarLoadFailedTitle,
                message: macCalendarStore.lastErrorMessage ?? L10n.macOSCalendarUnexpectedError,
                actionTitle: L10n.googleCalendarRetry,
                action: {
                    Task {
                        await macCalendarStore.refreshIfNeeded(force: true)
                    }
                }
            )
        case .loaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var emptyScheduleContent: some View {
        if settings.enabledCalendarSources.isEmpty {
            statusCard(
                title: L10n.calendarNoSourcesEnabledTitle,
                message: L10n.calendarNoSourcesEnabledMessage,
                actionTitle: L10n.settings,
                action: openCalendarSettings
            )
        } else if isAnyEnabledSourceLoading {
            ProgressView(L10n.calendarLoading)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } else if !upcomingEventsFromEnabledSources.isEmpty {
            statusCard(
                title: L10n.calendarNoEventsMatchFiltersTitle,
                message: L10n.calendarNoEventsMatchFiltersMessage,
                actionTitle: L10n.settings,
                action: openCalendarSettings
            )
        } else if hasLoadedEnabledSource || !hasEnabledSourceStatusCard {
            statusCard(
                title: L10n.googleCalendarNoUpcomingEventsTitle,
                message: L10n.calendarNoUpcomingEventsMessage
            )
        }
    }

    private func openCalendarSettings() {
        mainWindowNavigation.openSettings(category: .calendar)
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(eventSections) { section in
                CalendarScheduleSectionView(
                    section: section,
                    onSelectEvent: onSelectEvent,
                    onJoinEvent: onJoinEvent,
                    isAutoRecordingEnabled: calendarAutoRecordingStore.isEnabled,
                    onSetAutoRecording: { event, isEnabled in
                        calendarAutoRecordingStore.setEnabled(isEnabled, for: event)
                    }
                )
            }
        }
    }

    private var eventSections: [CalendarScheduleEventSection] {
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: visibleUpcomingEvents) {
            calendar.startOfDay(for: $0.startDate)
        }

        return grouped.keys.sorted().map { date in
            let title: String = if calendar.isDateInToday(date) {
                L10n.today
            } else if calendar.isDateInTomorrow(date) {
                L10n.tomorrow
            } else {
                date.formatted(.dateTime.weekday(.wide).month(.wide).day())
            }

            return CalendarScheduleEventSection(
                id: date.formatted(.iso8601.year().month().day()),
                title: title,
                events: grouped[date] ?? []
            )
        }
    }

    private var upcomingEventsFromEnabledSources: [CalendarEvent] {
        calendarSourceCoordinator.events(for: settings.enabledCalendarSources)
    }

    private var visibleUpcomingEvents: [CalendarEvent] {
        upcomingEventsFromEnabledSources
            .filter(settings.calendarEventFilter.includes)
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                if lhs.isAllDay != rhs.isAllDay {
                    return lhs.isAllDay
                }
                if lhs.endDate != rhs.endDate {
                    return lhs.endDate < rhs.endDate
                }
                if lhs.title != rhs.title {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.id < rhs.id
            }
    }

    private var isAnyEnabledSourceLoading: Bool {
        (settings.isCalendarSourceEnabled(.google) && googleCalendarStore.state == .loading)
            || (settings.isCalendarSourceEnabled(.macOS) && macCalendarStore.state == .loading)
    }

    private var hasLoadedEnabledSource: Bool {
        (settings.isCalendarSourceEnabled(.google) && googleCalendarStore.state == .loaded)
            || (settings.isCalendarSourceEnabled(.macOS) && macCalendarStore.state == .loaded)
    }

    private var hasEnabledSourceStatusCard: Bool {
        (settings.isCalendarSourceEnabled(.google) && googleCalendarStore.state.requiresUserAttention)
            || (settings.isCalendarSourceEnabled(.macOS) && macCalendarStore.state.requiresUserAttention)
    }

    private func refreshEnabledSources(force: Bool = false) async {
        await calendarSourceCoordinator.refreshEnabledSources(settings.enabledCalendarSources, force: force)
    }

    private func statusCard(
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }
}

private extension GoogleCalendarStore.State {
    var requiresUserAttention: Bool {
        switch self {
        case .unconfigured, .signedOut, .needsCalendarSelection, .failed:
            true
        case .loading, .loaded:
            false
        }
    }
}

private extension MacCalendarStore.State {
    var requiresUserAttention: Bool {
        switch self {
        case .notDetermined, .accessDenied, .needsCalendarSelection, .failed:
            true
        case .loading, .loaded:
            false
        }
    }
}

private struct CalendarScheduleEventSection: Identifiable {
    let id: String
    let title: String
    let events: [CalendarEvent]
}

private struct CalendarScheduleSectionView: View {
    let section: CalendarScheduleEventSection
    let onSelectEvent: (CalendarEvent) -> Void
    let onJoinEvent: (CalendarEvent) -> Void
    let isAutoRecordingEnabled: (CalendarEvent) -> Bool
    let onSetAutoRecording: (CalendarEvent, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(section.events) { event in
                    CalendarScheduleEventRow(
                        event: event,
                        onSelect: { onSelectEvent(event) },
                        onJoin: event.conferenceURI.map { _ in
                            { onJoinEvent(event) }
                        },
                        isAutoRecordingEnabled: isAutoRecordingEnabled(event),
                        onSetAutoRecording: { onSetAutoRecording(event, $0) }
                    )
                }
            }
        }
    }
}

private struct CalendarScheduleEventRow: View {
    let event: CalendarEvent
    let onSelect: () -> Void
    let onJoin: (() -> Void)?
    let isAutoRecordingEnabled: Bool
    let onSetAutoRecording: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onSelect) {
                HStack(alignment: .center, spacing: 12) {
                    Circle()
                        .fill(event.calendarColorHex.map(Color.init(hex:)) ?? Color.accentColor)
                        .frame(width: 9, height: 9)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
                if let onJoin {
                    Button(action: onJoin) {
                        Label(L10n.join, systemImage: "video.fill")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }

                if !event.isAllDay {
                    Toggle(isOn: autoRecordingBinding) {
                        Image(systemName: "timer")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .accessibilityLabel(L10n.calendarAutoRecording)
                    .help(L10n.calendarAutoRecordingHelp)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(isHovered ? DahliaDesign.hoverHighlightColor : .clear, in: RoundedRectangle(cornerRadius: 8))
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var autoRecordingBinding: Binding<Bool> {
        Binding(
            get: { isAutoRecordingEnabled },
            set: { isEnabled in onSetAutoRecording(isEnabled) }
        )
    }

    private var subtitle: String {
        let timeText: String
        if event.isAllDay {
            timeText = L10n.calendarAllDay
        } else {
            let start = event.startDate.formatted(date: .omitted, time: .shortened)
            let end = event.endDate.formatted(date: .omitted, time: .shortened)
            timeText = "\(start) - \(end)"
        }
        return "\(timeText) - \(event.calendarName)"
    }
}
