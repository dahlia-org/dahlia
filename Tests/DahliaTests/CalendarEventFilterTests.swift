import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CalendarEventFilterTests {
        @Test
        func includesRegularEventsByDefault() {
            #expect(CalendarEventFilter().includes(makeEvent()))
        }

        @Test
        func excludesOptionalEventTypesByDefault() {
            let filter = CalendarEventFilter()

            #expect(!filter.includes(makeEvent(isAllDay: true)))
            #expect(filter.includes(makeEvent(hasOtherAttendees: false)))
            #expect(filter.includes(makeEvent(conferenceURI: nil)))
            #expect(!filter.includes(makeEvent(isDeclined: true)))
            #expect(!filter.includes(makeEvent(isOutOfOffice: true)))
        }

        @Test
        func migratesLegacyExclusionSettingsWithoutOverwritingCurrentValues() throws {
            let suiteName = "CalendarEventFilterTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            defaults.set(false, forKey: "excludeAllDayCalendarEvents")
            defaults.set(true, forKey: "excludeCalendarEventsWithoutOtherAttendees")
            defaults.set(false, forKey: "includesCalendarEventsWithoutConferenceURI")

            AppSettings.migrateCalendarEventFilterSettings(in: defaults)

            #expect(defaults.bool(forKey: "includesAllDayCalendarEvents"))
            #expect(!defaults.bool(forKey: "includesCalendarEventsWithoutOtherAttendees"))
            #expect(!defaults.bool(forKey: "includesCalendarEventsWithoutConferenceURI"))
        }

        @Test
        func includesAllDayEventsWhenEnabled() {
            let filter = CalendarEventFilter(includesAllDayEvents: true)

            #expect(filter.includes(makeEvent(isAllDay: true)))
        }

        @Test
        func includesEventsWithoutOtherAttendeesWhenEnabled() {
            let filter = CalendarEventFilter(includesEventsWithoutOtherAttendees: true)

            #expect(filter.includes(makeEvent(hasOtherAttendees: false)))
        }

        @Test
        func includesEventsWithoutConferenceURIWhenEnabled() {
            let filter = CalendarEventFilter(includesEventsWithoutConferenceURI: true)

            #expect(filter.includes(makeEvent(conferenceURI: nil)))
        }

        @Test
        func includesDeclinedEventsWhenEnabled() {
            let filter = CalendarEventFilter(includesDeclinedEvents: true)

            #expect(filter.includes(makeEvent(isDeclined: true)))
        }

        @Test
        func includesOutOfOfficeEventsWhenEnabled() {
            let filter = CalendarEventFilter(includesOutOfOfficeEvents: true)

            #expect(filter.includes(makeEvent(isOutOfOffice: true)))
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
