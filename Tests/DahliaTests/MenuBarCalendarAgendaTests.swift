import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MenuBarCalendarAgendaTests {
        private let now = Date(timeIntervalSince1970: 1_773_576_000) // 2026-03-15 12:00:00 UTC
        private var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            return calendar
        }

        @Test
        func includesOnlyOngoingAndUpcomingEventsToday() {
            let ended = event(id: "ended", start: -7_200, end: -3_600)
            let overnight = event(id: "overnight", start: -46_800, end: 1_800)
            let upcoming = event(id: "upcoming", start: 3_600, end: 7_200)
            let tomorrow = event(id: "tomorrow", start: 46_800, end: 50_400)

            let agenda = agenda(googleEvents: [ended, overnight, upcoming, tomorrow])

            #expect(agenda.events.map(\.id) == [overnight.id, upcoming.id])
            #expect(agenda.featuredEvent?.id == overnight.id)
            #expect(agenda.featuredEventIsOngoing)
        }

        @Test
        func appliesEnabledSourcesFiltersAndCrossSourceDeduplication() {
            let googleEvent = event(
                id: "google",
                platform: CalendarEventPlatform.googleCalendar,
                icalUid: "shared",
                start: 3_600,
                end: 7_200
            )
            let duplicateMacEvent = event(
                id: "mac-duplicate",
                platform: CalendarEventPlatform.macOSCalendar,
                icalUid: "shared",
                start: 3_600,
                end: 7_200
            )
            let declined = event(id: "declined", start: 7_200, end: 10_800, isDeclined: true)

            let agenda = MenuBarCalendarAgenda(
                googleEvents: [googleEvent, declined],
                macEvents: [duplicateMacEvent],
                enabledSources: [.google, .macOS],
                filter: CalendarEventFilter(excludesDeclinedEvents: true),
                now: now,
                calendar: calendar
            )

            #expect(agenda.events.map(\.id) == [googleEvent.id])
        }

        @Test
        func prioritizesMostRecentlyStartedOngoingEventThenNextEvent() {
            let earlierOngoing = event(id: "earlier", start: -1_800, end: 3_600)
            let laterOngoing = event(id: "later", start: -600, end: 1_800)
            let next = event(id: "next", start: 3_600, end: 7_200)

            let ongoingAgenda = agenda(googleEvents: [next, earlierOngoing, laterOngoing])
            let upcomingAgenda = agenda(googleEvents: [next])

            #expect(ongoingAgenda.featuredEvent?.id == laterOngoing.id)
            #expect(ongoingAgenda.featuredEventIsOngoing)
            #expect(upcomingAgenda.featuredEvent?.id == next.id)
            #expect(!upcomingAgenda.featuredEventIsOngoing)
        }

        @Test
        func keepsAllDayEventsInListButNotInMenuBarLabel() {
            let startOfDay = calendar.startOfDay(for: now)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)
                ?? startOfDay.addingTimeInterval(86_400)
            let allDay = event(
                id: "all-day",
                startDate: startOfDay,
                endDate: endOfDay,
                isAllDay: true
            )

            let agenda = agenda(googleEvents: [allDay])

            #expect(agenda.events == [allDay])
            #expect(agenda.featuredEvent == nil)
        }

        @Test
        func roundsCountdownUpAndHonorsLabelSettings() {
            let upcoming = event(id: "upcoming", title: "Planning", start: 3_601, end: 7_200)
            let agenda = agenda(googleEvents: [upcoming])

            #expect(MenuBarCalendarAgenda.remainingMinutes(from: now, to: upcoming.startDate) == 61)
            #expect(agenda.labelText(showsTitle: true, showsCountdown: false, now: now) == "Planning")
            #expect(agenda.labelText(showsTitle: false, showsCountdown: false, now: now) == nil)
            #expect(agenda.labelText(showsTitle: false, showsCountdown: true, now: now)?.isEmpty == false)
            #expect(agenda.labelText(showsTitle: true, showsCountdown: true, now: now)?.contains("Planning") == true)
        }

        @Test
        func usesSoonTextForEventsStartingOrEndingInLessThanOneMinute() {
            let startingSoon = event(id: "starting", start: 59, end: 3_600)
            let endingSoon = event(id: "ending", start: -3_600, end: 59)

            #expect(agenda(googleEvents: [startingSoon]).countdownText(now: now) == L10n.menuBarStartingSoon)
            #expect(agenda(googleEvents: [endingSoon]).countdownText(now: now) == L10n.menuBarEndingSoon)
        }

        private func agenda(googleEvents: [CalendarEvent]) -> MenuBarCalendarAgenda {
            MenuBarCalendarAgenda(
                googleEvents: googleEvents,
                macEvents: [],
                enabledSources: [.google],
                filter: CalendarEventFilter(),
                now: now,
                calendar: calendar
            )
        }

        private func event(
            id: String,
            title: String = "Event",
            platform: String = CalendarEventPlatform.googleCalendar,
            icalUid: String? = nil,
            start: TimeInterval,
            end: TimeInterval,
            isAllDay: Bool = false,
            isDeclined: Bool = false
        ) -> CalendarEvent {
            event(
                id: id,
                title: title,
                platform: platform,
                icalUid: icalUid,
                startDate: now.addingTimeInterval(start),
                endDate: now.addingTimeInterval(end),
                isAllDay: isAllDay,
                isDeclined: isDeclined
            )
        }

        private func event(
            id: String,
            title: String = "Event",
            platform: String = CalendarEventPlatform.googleCalendar,
            icalUid: String? = nil,
            startDate: Date,
            endDate: Date,
            isAllDay: Bool = false,
            isDeclined: Bool = false
        ) -> CalendarEvent {
            CalendarEvent(
                id: id,
                calendarID: "calendar-\(platform)",
                calendarName: "Calendar",
                calendarColorHex: nil,
                platform: platform,
                platformId: id,
                title: title,
                description: "",
                icalUid: icalUid,
                startDate: startDate,
                endDate: endDate,
                isAllDay: isAllDay,
                isDeclined: isDeclined,
                conferenceURI: URL(string: "https://meet.example.com/\(id)")
            )
        }
    }
#endif
