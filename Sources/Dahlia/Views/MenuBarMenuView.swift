import SwiftUI

struct MenuBarMenuView: View {
    @ObservedObject var viewModel: CaptionViewModel
    let recordingCoordinator: RecordingCoordinator
    let calendarViewModel: MenuBarCalendarViewModel

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack {
            if settings.menuBarCalendarEnabled {
                MenuBarCalendarSectionView(
                    agenda: calendarViewModel.agenda,
                    now: calendarViewModel.currentDate,
                    canStartRecording: recordingCoordinator.canStartNewMeeting,
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
