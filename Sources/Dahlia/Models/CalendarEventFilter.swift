struct CalendarEventFilter: Equatable {
    let excludesAllDayEvents: Bool
    let excludesEventsWithoutOtherAttendees: Bool
    let excludesEventsWithoutConferenceURI: Bool
    let excludesDeclinedEvents: Bool
    let excludesOutOfOfficeEvents: Bool

    init(
        excludesAllDayEvents: Bool = false,
        excludesEventsWithoutOtherAttendees: Bool = false,
        excludesEventsWithoutConferenceURI: Bool = false,
        excludesDeclinedEvents: Bool = false,
        excludesOutOfOfficeEvents: Bool = false
    ) {
        self.excludesAllDayEvents = excludesAllDayEvents
        self.excludesEventsWithoutOtherAttendees = excludesEventsWithoutOtherAttendees
        self.excludesEventsWithoutConferenceURI = excludesEventsWithoutConferenceURI
        self.excludesDeclinedEvents = excludesDeclinedEvents
        self.excludesOutOfOfficeEvents = excludesOutOfOfficeEvents
    }

    func includes(_ event: CalendarEvent) -> Bool {
        if excludesAllDayEvents, event.isAllDay {
            return false
        }
        if excludesEventsWithoutOtherAttendees, !event.hasOtherAttendees {
            return false
        }
        if excludesEventsWithoutConferenceURI, event.conferenceURI == nil {
            return false
        }
        if excludesDeclinedEvents, event.isDeclined {
            return false
        }
        if excludesOutOfOfficeEvents, event.isOutOfOffice {
            return false
        }
        return true
    }
}
