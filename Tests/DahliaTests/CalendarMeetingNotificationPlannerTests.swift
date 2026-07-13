import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CalendarMeetingNotificationPlannerTests {
        @Test
        func schedulesExactlyOneMinuteBeforeAnEvent() throws {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let event = calendarEvent(startDate: now.addingTimeInterval(600))

            let notificationDate = try #require(
                CalendarMeetingNotificationPlanner.notificationDate(for: event, now: now)
            )

            #expect(notificationDate == event.startDate.addingTimeInterval(-60))
        }

        @Test
        func schedulesImmediatelyWhenTheOneMinuteBoundaryHasPassed() throws {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let event = calendarEvent(startDate: now.addingTimeInterval(30))

            let notificationDate = try #require(
                CalendarMeetingNotificationPlanner.notificationDate(for: event, now: now)
            )

            #expect(notificationDate == now.addingTimeInterval(1))
        }

        @Test
        func ignoresAllDayAndStartedEvents() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let allDayEvent = calendarEvent(startDate: now.addingTimeInterval(600), isAllDay: true)
            let startedEvent = calendarEvent(startDate: now.addingTimeInterval(-30))

            #expect(CalendarMeetingNotificationPlanner.notificationDate(for: allDayEvent, now: now) == nil)
            #expect(CalendarMeetingNotificationPlanner.notificationDate(for: startedEvent, now: now) == nil)
        }

        @Test
        func identifiesDeliveredNotificationsMissingFromTheCurrentSchedule() {
            let staleIdentifiers = CalendarMeetingNotificationPlanner.staleDeliveredIdentifiers(
                from: ["current", "canceled", "moved"],
                scheduledIdentifiers: ["current", "rescheduled"]
            )

            #expect(staleIdentifiers == ["canceled", "moved"])
        }

        @Test
        func appliesCalendarEventFilterToNotificationSchedule() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let included = calendarEvent(id: "included", startDate: now.addingTimeInterval(600))
            let outOfOffice = calendarEvent(
                id: "out-of-office",
                title: "Alex - OOTO",
                startDate: now.addingTimeInterval(300)
            )
            let filter = CalendarEventFilter(excludesOutOfOfficeEvents: true)

            let schedule = CalendarMeetingNotificationPlanner.schedule(
                for: [outOfOffice, included],
                filter: filter,
                now: now,
                limit: 50
            )

            #expect(schedule.map(\.event.id) == [included.id])
        }
    }
#endif

private func calendarEvent(
    id: String = "event-id",
    title: String = "Planning",
    startDate: Date,
    isAllDay: Bool = false
) -> CalendarEvent {
    CalendarEvent(
        id: id,
        calendarID: "calendar-id",
        calendarName: "Calendar",
        calendarColorHex: nil,
        platformId: id,
        title: title,
        description: "",
        icalUid: "uid",
        startDate: startDate,
        endDate: startDate.addingTimeInterval(3600),
        isAllDay: isAllDay,
        conferenceURI: URL(string: "https://meet.example.com/planning")
    )
}
