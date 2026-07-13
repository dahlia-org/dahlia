import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CalendarEventFilterTests {
        @Test
        func includesEventWhenNoFiltersAreEnabled() {
            let event = makeEvent(
                isAllDay: true,
                hasOtherAttendees: false,
                isDeclined: true,
                isOutOfOffice: true,
                conferenceURI: nil
            )

            #expect(CalendarEventFilter().includes(event))
        }

        @Test
        func excludesAllDayEvents() {
            let filter = CalendarEventFilter(excludesAllDayEvents: true)

            #expect(!filter.includes(makeEvent(isAllDay: true)))
            #expect(filter.includes(makeEvent()))
        }

        @Test
        func excludesEventsWithoutOtherAttendees() {
            let filter = CalendarEventFilter(excludesEventsWithoutOtherAttendees: true)

            #expect(!filter.includes(makeEvent(hasOtherAttendees: false)))
            #expect(filter.includes(makeEvent(hasOtherAttendees: true)))
        }

        @Test
        func excludesEventsWithoutConferenceURI() {
            let filter = CalendarEventFilter(excludesEventsWithoutConferenceURI: true)

            #expect(!filter.includes(makeEvent(conferenceURI: nil)))
            #expect(filter.includes(makeEvent(conferenceURI: URL(string: "https://meet.example.com/room"))))
        }

        @Test
        func excludesDeclinedEvents() {
            let filter = CalendarEventFilter(excludesDeclinedEvents: true)

            #expect(!filter.includes(makeEvent(isDeclined: true)))
            #expect(filter.includes(makeEvent(isDeclined: false)))
        }

        @Test
        func excludesOutOfOfficeEvents() {
            let filter = CalendarEventFilter(excludesOutOfOfficeEvents: true)

            #expect(!filter.includes(makeEvent(isOutOfOffice: true)))
            #expect(filter.includes(makeEvent(isOutOfOffice: false)))
        }

        @Test(arguments: [
            "OOO",
            "Alex - OOTO",
            "OOO: Vacation",
        ])
        func recognizesOutOfOfficeTitleTokens(_ title: String) {
            #expect(CalendarEvent.titleIndicatesOutOfOffice(title))
        }

        @Test(arguments: ["Oolong", "MOOTO planning", "OOOrder review"])
        func ignoresOutOfOfficeAcronymsInsideWords(_ title: String) {
            #expect(!CalendarEvent.titleIndicatesOutOfOffice(title))
        }

        private func makeEvent(
            isAllDay: Bool = false,
            hasOtherAttendees: Bool = true,
            isDeclined: Bool = false,
            isOutOfOffice: Bool = false,
            conferenceURI: URL? = URL(string: "https://meet.example.com/room")
        ) -> CalendarEvent {
            CalendarEvent(
                id: "event",
                calendarID: "calendar",
                calendarName: "Work",
                calendarColorHex: nil,
                platformId: "event",
                title: "Planning",
                description: "",
                icalUid: nil,
                startDate: Date(timeIntervalSince1970: 1_776_387_600),
                endDate: Date(timeIntervalSince1970: 1_776_391_200),
                isAllDay: isAllDay,
                hasOtherAttendees: hasOtherAttendees,
                isDeclined: isDeclined,
                isOutOfOffice: isOutOfOffice,
                conferenceURI: conferenceURI
            )
        }
    }
#endif
