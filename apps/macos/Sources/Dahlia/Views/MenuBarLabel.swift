import SwiftUI

struct MenuBarLabel: View {
    let viewModel: CaptionViewModel
    let calendarViewModel: MenuBarCalendarViewModel

    @ObservedObject private var settings = AppSettings.shared
    @State private var isListening = false

    var body: some View {
        let agenda = calendarViewModel.agenda
        let calendarText = settings.menuBarCalendarEnabled
            && (agenda.featuredEvent != nil || calendarViewModel.allEnabledSourcesAreLoaded)
            ? agenda.labelText(
                showsTitle: settings.menuBarCalendarShowsEventTitle,
                showsCountdown: settings.menuBarCalendarShowsCountdown,
                now: calendarViewModel.currentDate
            )
            : nil
        let calendarAccessibilityLabel = calendarText == nil
            ? L10n.dahlia
            : agenda.accessibilityLabel(now: calendarViewModel.currentDate) ?? L10n.dahlia
        let accessibilityLabel = isListening
            ? "\(calendarAccessibilityLabel), \(L10n.recordingNow)"
            : calendarAccessibilityLabel

        Group {
            if settings.menuBarCalendarEnabled,
               let calendarText {
                Label {
                    Text(calendarText)
                } icon: {
                    if isListening {
                        Image(systemName: "record.circle.fill")
                    } else if let featuredEvent = agenda.featuredEvent {
                        MenuBarCalendarParticipationIndicator(isAttending: featuredEvent.isAttending)
                    } else {
                        Image(systemName: "waveform")
                    }
                }
            } else {
                Label(
                    L10n.dahlia,
                    systemImage: isListening ? "record.circle.fill" : "waveform"
                )
            }
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityLabel(accessibilityLabel)
        .onReceive(viewModel.$isListening) { isListening = $0 }
        .task {
            isListening = viewModel.isListening
            await calendarViewModel.runRefreshLoop()
        }
    }
}
