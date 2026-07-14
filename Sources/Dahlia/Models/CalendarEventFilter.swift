struct CalendarEventFilter: Equatable {
    let includesAllDayEvents: Bool
    let includesEventsWithoutOtherAttendees: Bool
    let includesEventsWithoutConferenceURI: Bool
    let includesDeclinedEvents: Bool
    let includesOutOfOfficeEvents: Bool

    init(
        includesAllDayEvents: Bool = false,
        includesEventsWithoutOtherAttendees: Bool = false,
        includesEventsWithoutConferenceURI: Bool = false,
        includesDeclinedEvents: Bool = false,
        includesOutOfOfficeEvents: Bool = false
    ) {
        self.includesAllDayEvents = includesAllDayEvents
        self.includesEventsWithoutOtherAttendees = includesEventsWithoutOtherAttendees
        self.includesEventsWithoutConferenceURI = includesEventsWithoutConferenceURI
        self.includesDeclinedEvents = includesDeclinedEvents
        self.includesOutOfOfficeEvents = includesOutOfOfficeEvents
    }

    func includes(_ event: CalendarEvent) -> Bool {
        if !includesAllDayEvents, event.isAllDay {
            return false
        }
        if !includesEventsWithoutOtherAttendees, !event.hasOtherAttendees {
            return false
        }
        if !includesEventsWithoutConferenceURI, event.conferenceURI == nil {
            return false
        }
        if !includesDeclinedEvents, event.isDeclined {
            return false
        }
        if !includesOutOfOfficeEvents, event.isOutOfOffice {
            return false
        }
        return true
    }
}
