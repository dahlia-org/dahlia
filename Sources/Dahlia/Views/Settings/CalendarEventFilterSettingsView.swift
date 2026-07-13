import SwiftUI

struct CalendarEventFilterSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            Toggle(isOn: $settings.excludeAllDayCalendarEvents) {
                Text(L10n.calendarFilterAllDayEvents)
                Text(L10n.calendarFilterAllDayEventsDescription)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $settings.excludeCalendarEventsWithoutOtherAttendees) {
                Text(L10n.calendarFilterUserOnlyEvents)
                Text(L10n.calendarFilterUserOnlyEventsDescription)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $settings.excludeCalendarEventsWithoutConferenceURI) {
                Text(L10n.calendarFilterEventsWithoutMeetingURL)
                Text(L10n.calendarFilterEventsWithoutMeetingURLDescription)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $settings.excludeDeclinedCalendarEvents) {
                Text(L10n.calendarFilterDeclinedEvents)
                Text(L10n.calendarFilterDeclinedEventsDescription)
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $settings.excludeOutOfOfficeCalendarEvents) {
                Text(L10n.calendarFilterOutOfOfficeEvents)
                Text(L10n.calendarFilterOutOfOfficeEventsDescription)
            }
            .toggleStyle(.checkbox)
        } header: {
            Text(L10n.calendarEventFilters)
        } footer: {
            Text(L10n.calendarEventFiltersDescription)
        }
    }
}
