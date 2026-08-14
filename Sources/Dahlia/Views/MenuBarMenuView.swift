import SwiftUI

struct MenuBarMenuView: View {
    let recordingCoordinator: RecordingCoordinator
    let calendarViewModel: MenuBarCalendarViewModel
    let mainWindowNavigation: MainWindowNavigation

    @State private var recordingState: MenuBarRecordingState
    @ObservedObject private var settings = AppSettings.shared

    init(
        viewModel: CaptionViewModel,
        recordingCoordinator: RecordingCoordinator,
        calendarViewModel: MenuBarCalendarViewModel,
        mainWindowNavigation: MainWindowNavigation
    ) {
        self.recordingCoordinator = recordingCoordinator
        self.calendarViewModel = calendarViewModel
        self.mainWindowNavigation = mainWindowNavigation
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

            MenuBarAppActionsView(mainWindowNavigation: mainWindowNavigation)
        }
    }

    private func joinAndRecordEvent(_ event: CalendarEvent) {
        recordingCoordinator.joinCalendarEventAndStartRecording(event)
    }

    private func joinEvent(_ event: CalendarEvent) {
        recordingCoordinator.openMeetingLink(for: event)
    }

    private func showEventInCalendar(_ event: CalendarEvent) {
        guard let eventURL = event.url else { return }
        NSWorkspace.shared.open(eventURL)
    }

    private func openCalendarSettings() {
        mainWindowNavigation.openSettings(category: .calendar)
    }
}
