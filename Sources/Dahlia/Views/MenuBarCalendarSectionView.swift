import SwiftUI

struct MenuBarCalendarSectionView: View {
    let agenda: MenuBarCalendarAgenda
    let now: Date
    let onOpenEvent: (CalendarEvent) -> Void
    let onJoinEvent: (CalendarEvent) -> Void
    let onOpenCalendarSettings: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var googleCalendarStore = GoogleCalendarStore.shared
    @ObservedObject private var macCalendarStore = MacCalendarStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.today, systemImage: "calendar")
                .font(.headline)

            if !settings.enabledCalendarSources.isEmpty, !agenda.events.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(agenda.events) { event in
                            MenuBarCalendarEventRow(
                                event: event,
                                now: now,
                                onOpen: { onOpenEvent(event) },
                                onJoin: event.conferenceURI == nil ? nil : { onJoinEvent(event) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 300)
            } else {
                emptyContent
            }
        }
        .padding()
    }

    @ViewBuilder
    private var emptyContent: some View {
        if settings.enabledCalendarSources.isEmpty {
            unavailableView(
                title: L10n.calendarNoSourcesEnabledTitle,
                message: L10n.calendarNoSourcesEnabledMessage
            )
        } else if isLoading {
            ProgressView(L10n.calendarLoading)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let issue = sourceIssue {
            unavailableView(title: issue.title, message: issue.message)
        } else {
            ContentUnavailableView(
                L10n.menuBarNoMoreEventsToday,
                systemImage: "calendar.badge.checkmark",
                description: Text(L10n.menuBarNoMoreEventsTodayDescription)
            )
            .frame(minHeight: 120)
        }
    }

    private func unavailableView(title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button(L10n.menuBarOpenCalendarSettings, action: onOpenCalendarSettings)
        }
        .frame(minHeight: 140)
    }

    private var isLoading: Bool {
        (settings.isCalendarSourceEnabled(.google) && googleCalendarStore.state == .loading)
            || (settings.isCalendarSourceEnabled(.macOS) && macCalendarStore.state == .loading)
    }

    private var sourceIssue: (title: String, message: String)? {
        if settings.isCalendarSourceEnabled(.google) {
            switch googleCalendarStore.state {
            case .unconfigured:
                return (L10n.googleCalendarClientIDMissingTitle, L10n.googleCalendarClientIDMissingMessage)
            case .signedOut:
                return (L10n.googleCalendarSignInRequiredTitle, L10n.googleCalendarScheduleSignInRequiredMessage)
            case .needsCalendarSelection:
                return (L10n.calendarSelectionRequiredTitle, L10n.calendarScheduleSelectionRequiredMessage)
            case .failed:
                return (
                    L10n.googleCalendarLoadFailedTitle,
                    googleCalendarStore.lastErrorMessage ?? L10n.googleCalendarUnexpectedResponse
                )
            case .loading, .loaded:
                break
            }
        }

        if settings.isCalendarSourceEnabled(.macOS) {
            switch macCalendarStore.state {
            case .notDetermined:
                return (L10n.macOSCalendarAccessRequiredTitle, L10n.macOSCalendarAccessRequiredMessage)
            case .accessDenied:
                return (L10n.macOSCalendarAccessDeniedTitle, L10n.macOSCalendarAccessDeniedMessage)
            case .needsCalendarSelection:
                return (L10n.calendarSelectionRequiredTitle, L10n.calendarScheduleSelectionRequiredMessage)
            case .failed:
                return (
                    L10n.macOSCalendarLoadFailedTitle,
                    macCalendarStore.lastErrorMessage ?? L10n.macOSCalendarUnexpectedError
                )
            case .loading, .loaded:
                break
            }
        }

        return nil
    }
}
