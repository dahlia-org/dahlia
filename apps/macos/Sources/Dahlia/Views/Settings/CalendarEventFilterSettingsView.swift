import SwiftUI

struct CalendarEventFilterSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            Toggle(isOn: $settings.includesAllDayCalendarEvents) {
                Text(L10n.calendarFilterAllDayEvents)
                Text(L10n.calendarIncludeAllDayEventsDescription)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $settings.includesCalendarEventsWithoutOtherAttendees) {
                Text(L10n.calendarFilterUserOnlyEvents)
                Text(L10n.calendarIncludeUserOnlyEventsDescription)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $settings.includesCalendarEventsWithoutConferenceURI) {
                Text(L10n.calendarFilterEventsWithoutMeetingURL)
                Text(L10n.calendarIncludeEventsWithoutMeetingURLDescription)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $settings.includesDeclinedCalendarEvents) {
                Text(L10n.calendarFilterDeclinedEvents)
                Text(L10n.calendarIncludeDeclinedEventsDescription)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $settings.includesOutOfOfficeCalendarEvents) {
                Text(L10n.calendarFilterOutOfOfficeEvents)
                Text(L10n.calendarIncludeOutOfOfficeEventsDescription)
            }
            .toggleStyle(.checkbox)
        } header: {
            Text(L10n.calendarEventsToInclude)
        } footer: {
            Text(L10n.calendarEventsToIncludeDescription)
        }
    }
}
