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
        let calendarAccessibilityLabel = calendarText == nil
            ? L10n.dahlia
            : agenda.accessibilityLabel(now: calendarViewModel.currentDate) ?? L10n.dahlia
        let accessibilityLabel = viewModel.isListening
            ? "\(calendarAccessibilityLabel), \(L10n.recordingNow)"
            : calendarAccessibilityLabel

        Group {
            if settings.menuBarCalendarEnabled,
               let featuredEvent = agenda.featuredEvent,
               let calendarText {
                Label {
                    Text(calendarText)
                } icon: {
                    if viewModel.isListening {
                        Image(systemName: "record.circle.fill")
                    } else {
                        MenuBarCalendarParticipationIndicator(isAttending: featuredEvent.isAttending)
                    }
                }
            } else if settings.menuBarCalendarEnabled {
                if viewModel.isListening {
                    Label(L10n.dahlia, systemImage: "record.circle.fill")
                } else {
                    Text(calendarText ?? L10n.dahlia)
                }
            } else {
                Label(
                    L10n.dahlia,
                    systemImage: viewModel.isListening ? "record.circle.fill" : "waveform"
                )
            }
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityLabel(accessibilityLabel)
        .task {
            await calendarViewModel.runRefreshLoop()
        }
    }
}
