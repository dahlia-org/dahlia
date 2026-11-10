import SwiftUI

/// Calendar settings for the whole app: the menu bar, the apps that open meeting links, and which events appear.
/// Each account's calendar sources are in `CalendarSettingsView`.
struct CalendarDisplaySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.menuBarCalendarEnabled) {
                    Text(L10n.menuBarCalendarDisplay)
                    Text(L10n.menuBarCalendarDisplayDescription)
                }
                .toggleStyle(.switch)

                Toggle(isOn: $settings.menuBarCalendarShowsEventTitle) {
                    Text(L10n.menuBarCalendarEventTitle)
                    Text(L10n.menuBarCalendarEventTitleDescription)
                }
                .toggleStyle(.switch)
                .disabled(!settings.menuBarCalendarEnabled)

                Toggle(isOn: $settings.menuBarCalendarShowsCountdown) {
                    Text(L10n.menuBarCalendarCountdown)
                    Text(L10n.menuBarCalendarCountdownDescription)
                }
                .toggleStyle(.switch)
                .disabled(!settings.menuBarCalendarEnabled)
            } header: {
                Text(L10n.menuBarCalendar)
            } footer: {
                Text(L10n.menuBarCalendarDescription)
            }

            MeetingLinkSettingsView()

            CalendarEventFilterSettingsView(settings: settings)
        }
        .formStyle(.grouped)
    }
}
