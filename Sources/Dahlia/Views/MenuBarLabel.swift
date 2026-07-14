import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var viewModel: CaptionViewModel
    let calendarViewModel: MenuBarCalendarViewModel

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var googleCalendarStore = GoogleCalendarStore.shared
    @ObservedObject private var macCalendarStore = MacCalendarStore.shared

    var body: some View {
        let agenda = MenuBarCalendarAgenda(
            googleEvents: googleCalendarStore.upcomingEvents,
            macEvents: macCalendarStore.upcomingEvents,
            enabledSources: settings.enabledCalendarSources,
            filter: settings.calendarEventFilter,
            now: calendarViewModel.currentDate
        )
        let calendarText = settings.menuBarCalendarEnabled
            ? agenda.labelText(
                showsTitle: settings.menuBarCalendarShowsEventTitle,
                showsCountdown: settings.menuBarCalendarShowsCountdown,
                now: calendarViewModel.currentDate
            )
            : nil

        Label {
            Text(calendarText ?? L10n.dahlia)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 320)
        } icon: {
            Image(systemName: viewModel.isListening ? "record.circle.fill" : "waveform")
        }
        .accessibilityLabel(
            calendarText == nil
                ? L10n.dahlia
                : agenda.accessibilityLabel(now: calendarViewModel.currentDate) ?? L10n.dahlia
        )
        .task {
            await calendarViewModel.runRefreshLoop()
        }
    }
}
