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
    }
#endif

private func calendarEvent(startDate: Date, isAllDay: Bool = false) -> CalendarEvent {
    CalendarEvent(
        id: "event-id",
        calendarID: "calendar-id",
        calendarName: "Calendar",
        calendarColorHex: nil,
        platformId: "platform-id",
        title: "Planning",
        description: "",
        icalUid: "uid",
        startDate: startDate,
        endDate: startDate.addingTimeInterval(3600),
        isAllDay: isAllDay,
        meetingURL: URL(string: "https://meet.example.com/planning")
    )
}
