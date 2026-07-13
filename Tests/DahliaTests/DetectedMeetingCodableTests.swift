import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct DetectedMeetingCodableTests {
        @Test
        func preservesCalendarDetailsUsedByNotificationActions() throws {
            let startDate = Date(timeIntervalSince1970: 1_700_000_000)
            let event = CalendarEvent(
                id: "event-id",
                calendarID: "calendar-id",
                calendarName: "Work",
                calendarColorHex: "3366FF",
                platform: CalendarEventPlatform.macOSCalendar,
                platformId: "platform-id",
                title: "Planning",
                description: "Quarterly planning",
                icalUid: "uid",
                startDate: startDate,
                endDate: startDate.addingTimeInterval(3600),
                isAllDay: false,
                hasOtherAttendees: true,
                isDeclined: true,
                isOutOfOffice: true,
                conferenceURI: URL(string: "https://meet.example.com/planning"),
                url: URL(string: "https://calendar.example.com/events/planning")
            )
            let meeting = DetectedMeeting(
                title: event.title,
                appName: "Calendar",
                bundleIdentifier: event.platform,
                calendarEvent: event
            )

            let data = try JSONEncoder().encode(meeting)
            let decoded = try JSONDecoder().decode(DetectedMeeting.self, from: data)

            #expect(decoded.id == meeting.id)
            #expect(decoded.title == meeting.title)
            #expect(decoded.calendarEvent == event)
        }

        @Test
        func decodesLegacyMeetingAndSourceEventURLs() throws {
            let event = CalendarEvent(
                id: "event-id",
                calendarID: "calendar-id",
                calendarName: "Work",
                calendarColorHex: nil,
                platformId: "platform-id",
                title: "Planning",
                description: "",
                icalUid: "uid",
                startDate: Date(timeIntervalSince1970: 1_700_000_000),
                endDate: Date(timeIntervalSince1970: 1_700_003_600),
                isAllDay: false,
                conferenceURI: URL(string: "https://meet.example.com/planning"),
                url: URL(string: "https://calendar.example.com/events/planning")
            )
            let encoded = try JSONEncoder().encode(event)
            var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            legacyObject["meetingURL"] = legacyObject.removeValue(forKey: "conferenceURI")
            legacyObject["sourceEventURL"] = legacyObject.removeValue(forKey: "url")
            legacyObject.removeValue(forKey: "recurrenceId")
            legacyObject.removeValue(forKey: "hasOtherAttendees")
            legacyObject.removeValue(forKey: "isDeclined")
            legacyObject.removeValue(forKey: "isOutOfOffice")
            let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

            let decoded = try JSONDecoder().decode(CalendarEvent.self, from: legacyData)

            #expect(decoded.conferenceURI == event.conferenceURI)
            #expect(decoded.url == event.url)
            #expect(decoded.recurrenceId.isEmpty)
            #expect(!decoded.hasOtherAttendees)
            #expect(!decoded.isDeclined)
            #expect(!decoded.isOutOfOffice)
        }
    }
#endif
