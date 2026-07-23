import SwiftUI

struct MenuBarMenuView: View {
    let recordingCoordinator: RecordingCoordinator
    let calendarViewModel: MenuBarCalendarViewModel

    @State private var recordingState: MenuBarRecordingState
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    init(
        viewModel: CaptionViewModel,
        recordingCoordinator: RecordingCoordinator,
        calendarViewModel: MenuBarCalendarViewModel
    ) {
        self.recordingCoordinator = recordingCoordinator
        self.calendarViewModel = calendarViewModel
        _recordingState = State(initialValue: MenuBarRecordingState(viewModel: viewModel))
    }

    var body: some View {
        VStack {
            if settings.menuBarCalendarEnabled {
                MenuBarCalendarSectionView(
                    agenda: calendarViewModel.agenda,
                    now: calendarViewModel.currentDate,
                    canStartRecording: recordingState.canBeginRecording
                        && recordingCoordinator.canStartNewMeeting,
                    onJoinAndRecordEvent: joinAndRecordEvent,
                    onJoinEvent: joinEvent,
                    onShowEventInCalendar: showEventInCalendar,
                    onOpenCalendarSettings: openCalendarSettings
                )

                Divider()
            }

            MenuBarRecordingControls(
                state: recordingState,
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
