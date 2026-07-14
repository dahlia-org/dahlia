import SwiftUI

struct MenuBarCalendarSectionView: View {
    let agenda: MenuBarCalendarAgenda
    let now: Date
    let onJoinAndRecordEvent: (CalendarEvent) -> Void
    let onJoinEvent: (CalendarEvent) -> Void
    let onShowEventInCalendar: (CalendarEvent) -> Void
    let onOpenCalendarSettings: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var googleCalendarStore = GoogleCalendarStore.shared
    @ObservedObject private var macCalendarStore = MacCalendarStore.shared

    var body: some View {
        Section(L10n.today) {
            if !settings.enabledCalendarSources.isEmpty, !agenda.events.isEmpty {
                ForEach(agenda.events) { event in
                    MenuBarCalendarEventRow(
                        event: event,
                        now: now,
                        canJoin: event.conferenceURI != nil,
                        canShowInCalendar: event.url != nil,
                        onJoinAndRecord: { onJoinAndRecordEvent(event) },
                        onJoin: { onJoinEvent(event) },
                        onShowInCalendar: { onShowEventInCalendar(event) }
                    )
                }
            } else if settings.enabledCalendarSources.isEmpty {
                statusLabel(L10n.calendarNoSourcesEnabledTitle, systemImage: "calendar.badge.exclamationmark")
                calendarSettingsButton
            } else if isLoading {
                statusLabel(L10n.calendarLoading, systemImage: "arrow.triangle.2.circlepath")
            } else if let issueTitle = sourceIssueTitle {
                statusLabel(issueTitle, systemImage: "calendar.badge.exclamationmark")
                calendarSettingsButton
            } else {
                statusLabel(L10n.menuBarNoMoreEventsToday, systemImage: "calendar.badge.checkmark")
            }
        }
    }

    private func statusLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .disabled(true)
    }

    private var calendarSettingsButton: some View {
        Button(L10n.menuBarOpenCalendarSettings, systemImage: "gearshape", action: onOpenCalendarSettings)
    }

    private var isLoading: Bool {
        (settings.isCalendarSourceEnabled(.google) && googleCalendarStore.state == .loading)
            || (settings.isCalendarSourceEnabled(.macOS) && macCalendarStore.state == .loading)
    }

    private var sourceIssueTitle: String? {
        if settings.isCalendarSourceEnabled(.google) {
            switch googleCalendarStore.state {
            case .unconfigured:
                return L10n.googleCalendarClientIDMissingTitle
            case .signedOut:
                return L10n.googleCalendarSignInRequiredTitle
            case .needsCalendarSelection:
                return L10n.calendarSelectionRequiredTitle
            case .failed:
                return L10n.googleCalendarLoadFailedTitle
            case .loading, .loaded:
                break
            }
        }

        if settings.isCalendarSourceEnabled(.macOS) {
            switch macCalendarStore.state {
            case .notDetermined:
                return L10n.macOSCalendarAccessRequiredTitle
            case .accessDenied:
                return L10n.macOSCalendarAccessDeniedTitle
            case .needsCalendarSelection:
                return L10n.calendarSelectionRequiredTitle
            case .failed:
                return L10n.macOSCalendarLoadFailedTitle
            case .loading, .loaded:
                break
            }
        }

        return nil
    }
}
