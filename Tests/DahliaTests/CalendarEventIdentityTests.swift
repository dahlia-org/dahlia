import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CalendarEventIdentityTests {
        @Test
        func recurrenceIdUsesRFC5545UTCDateTimeAndDateForms() {
            let date = Date(timeIntervalSince1970: 1_776_382_200)

            #expect(ICalendarRecurrenceID.dateTime(date) == "20260416T233000Z")
            #expect(ICalendarRecurrenceID.date("2026-04-17") == "20260417")
            #expect(ICalendarRecurrenceID.date("2026-4-17") == nil)
        }

        @Test
        func singleEventUsesEmptyRecurrenceId() {
            let event = makeEvent(platform: CalendarEventPlatform.googleCalendar)

            #expect(event.recurrenceId.isEmpty)
            #expect(event.key == CalendarEventKey(icalUid: "shared@example.com", recurrenceId: ""))
        }

        @Test
        func deduplicationUsesOriginalOccurrenceInsteadOfCurrentStart() {
            let recurrenceId = "20260417T003000Z"
            let macEvent = makeEvent(
                platform: CalendarEventPlatform.macOSCalendar,
                recurrenceId: recurrenceId,
                startDate: Date(timeIntervalSince1970: 1_776_390_600)
            )
            let googleEvent = makeEvent(
                platform: CalendarEventPlatform.googleCalendar,
                recurrenceId: recurrenceId,
                startDate: Date(timeIntervalSince1970: 1_776_391_200)
            )

            let result = [macEvent, googleEvent].deduplicatedAcrossSources()

            #expect(result == [googleEvent])
        }

        @Test
        func differentOccurrencesRemainDistinct() {
            let first = makeEvent(
                platform: CalendarEventPlatform.macOSCalendar,
                recurrenceId: "20260417T003000Z"
            )
            let second = makeEvent(
                platform: CalendarEventPlatform.googleCalendar,
                recurrenceId: "20260424T003000Z"
            )

            #expect([first, second].deduplicatedAcrossSources() == [first, second])
        }

        @Test
        func deduplicationKeepsComplementaryMetadataFromMacOS() {
            let recurrenceId = "20260417T003000Z"
            let conferenceURI = URL(string: "https://zoom.us/j/123456789")
            let eventURL = URL(string: "https://calendar.google.com/calendar/event?eid=planning")
            let googleEvent = makeEvent(
                platform: CalendarEventPlatform.googleCalendar,
                recurrenceId: recurrenceId,
                url: eventURL
            )
            let macEvent = makeEvent(
                platform: CalendarEventPlatform.macOSCalendar,
                recurrenceId: recurrenceId,
                description: "Join the weekly planning call",
                conferenceURI: conferenceURI
            )
            let expected = makeEvent(
                platform: CalendarEventPlatform.googleCalendar,
                recurrenceId: recurrenceId,
                description: macEvent.description,
                conferenceURI: conferenceURI,
                url: eventURL
            )

            #expect([googleEvent, macEvent].deduplicatedAcrossSources() == [expected])
            #expect([macEvent, googleEvent].deduplicatedAcrossSources() == [expected])
        }
    }

    private func makeEvent(
        platform: String,
        recurrenceId: String = ICalendarRecurrenceID.singleEvent,
        startDate: Date = Date(timeIntervalSince1970: 1_776_387_600),
        description: String = "",
        conferenceURI: URL? = nil,
        url: URL? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: "\(platform)-event",
            calendarID: platform,
            calendarName: platform,
            calendarColorHex: nil,
            platform: platform,
            platformId: "source-event",
            title: "Planning",
            description: description,
            icalUid: "shared@example.com",
            recurrenceId: recurrenceId,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600),
            isAllDay: false,
            conferenceURI: conferenceURI,
            url: url
        )
    }
#endif
