#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct MainSidebarUpcomingEventsSectionTests {
        @Test(arguments: ["Asia/Tokyo", "America/Los_Angeles"])
        func excludesEventsStartingAtOrAfterLocalMidnight(timeZone: String) throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: timeZone))
            // March 8 has only 23 hours in Los Angeles; use calendar days rather than 24-hour offsets.
            let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
            let today = calendar.startOfDay(for: now)
            let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: today))
            let overnight = event(id: "overnight", start: today.addingTimeInterval(-3600), end: tomorrow)
            let upcoming = event(id: "today", start: tomorrow.addingTimeInterval(-60), end: tomorrow.addingTimeInterval(3600))
            let nextDay = event(id: "tomorrow", start: tomorrow, end: tomorrow.addingTimeInterval(3600))
            let events = [overnight, upcoming, nextDay]

            let visible = MainSidebarUpcomingEventsSection.visibleEvents(from: events, now: now, calendar: calendar)
            let agenda = MenuBarCalendarAgenda(
                events: events,
                filter: CalendarEventFilter(includesUnconfirmedEvents: true, includesDeclinedEvents: true),
                now: now,
                calendar: calendar
            )

            #expect(visible.map(\.id) == [overnight.id, upcoming.id])
            #expect(visible == agenda.events)
            #expect(MainSidebarUpcomingEventsSection.visibleEvents(from: [nextDay], now: now, calendar: calendar).isEmpty)
            #expect(MainSidebarUpcomingEventsSection.visibleEvents(from: [nextDay], now: tomorrow, calendar: calendar) == [nextDay])
        }

        @Test
        func keepsTheFiveEventLimitAndScheduleOrder() {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let events = (0 ..< 6).map { index in
                event(id: "event-\(index)", start: now.addingTimeInterval(Double(index)), end: now.addingTimeInterval(3600))
            }

            #expect(MainSidebarUpcomingEventsSection.visibleEvents(from: events, now: now) == Array(events.prefix(5)))
        }

        private func event(id: String, start: Date, end: Date) -> CalendarEvent {
            CalendarEvent(
                id: id, calendarID: "calendar", calendarName: "Calendar", calendarColorHex: nil,
                platformId: id, title: id, description: "", icalUid: nil,
                startDate: start, endDate: end, isAllDay: false, conferenceURI: nil
            )
        }
    }
#endif
