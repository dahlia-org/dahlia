import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CalendarEventTitleTests {
        @Test
        func resolvedMeetingTitleTrimsWhitespace() {
            #expect(calendarEvent(title: "  Planning  ").resolvedMeetingTitle == "Planning")
        }

        @Test
        func resolvedMeetingTitleFallsBackForBlankTitles() {
            #expect(calendarEvent(title: " \n ").resolvedMeetingTitle == L10n.newMeeting)
        }
    }
#endif

private func calendarEvent(title: String) -> CalendarEvent {
    let startDate = Date(timeIntervalSince1970: 1_700_000_000)
    return CalendarEvent(
        id: "event-id",
        calendarID: "calendar-id",
        calendarName: "Calendar",
        calendarColorHex: nil,
        platformId: "platform-id",
        title: title,
        description: "",
        icalUid: "uid",
        startDate: startDate,
        endDate: startDate.addingTimeInterval(3600),
        isAllDay: false,
        conferenceURI: nil
    )
}
