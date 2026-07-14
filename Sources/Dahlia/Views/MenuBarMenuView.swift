import SwiftUI

struct MenuBarMenuView: View {
    @ObservedObject var viewModel: CaptionViewModel
    let recordingCoordinator: RecordingCoordinator
    let calendarViewModel: MenuBarCalendarViewModel

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var googleCalendarStore = GoogleCalendarStore.shared
    @ObservedObject private var macCalendarStore = MacCalendarStore.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let agenda = MenuBarCalendarAgenda(
            googleEvents: googleCalendarStore.upcomingEvents,
            macEvents: macCalendarStore.upcomingEvents,
            enabledSources: settings.enabledCalendarSources,
            filter: settings.calendarEventFilter,
            now: calendarViewModel.currentDate
        )

        VStack(spacing: 0) {
            if settings.menuBarCalendarEnabled {
                MenuBarCalendarSectionView(
                    agenda: agenda,
                    now: calendarViewModel.currentDate,
                    onJoinAndRecordEvent: joinAndRecordEvent,
                    onJoinEvent: joinEvent,
                    onShowEventInCalendar: showEventInCalendar,
                    onOpenCalendarSettings: openCalendarSettings
                )

                Divider()
            }

            MenuBarRecordingControls(
                viewModel: viewModel,
                recordingCoordinator: recordingCoordinator
            )

            Divider()

            MenuBarAppActionsView()
        }
        .frame(minWidth: 380, idealWidth: 420, maxWidth: 460)
    }

    private func joinAndRecordEvent(_ event: CalendarEvent) {
        recordingCoordinator.joinCalendarEventAndStartRecording(event)
    }

    private func joinEvent(_ event: CalendarEvent) {
        guard let conferenceURI = event.conferenceURI else { return }
        NSWorkspace.shared.open(conferenceURI)
    }

    private func showEventInCalendar(_ event: CalendarEvent) {
        guard let eventURL = event.url else { return }
        NSWorkspace.shared.open(eventURL)
    }

    private func openCalendarSettings() {
        UserDefaults.standard.set(
            SettingsCategory.calendar.rawValue,
            forKey: SettingsNavigation.selectedCategoryDefaultsKey
        )
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}
