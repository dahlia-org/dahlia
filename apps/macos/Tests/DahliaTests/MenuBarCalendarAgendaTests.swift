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
            let ended = event(id: "ended", start: -7200, end: -3600)
            let overnight = event(id: "overnight", start: -46800, end: 1800)
            let upcoming = event(id: "upcoming", start: 3600, end: 7200)
            let tomorrow = event(id: "tomorrow", start: 46800, end: 50400)

            let agenda = agenda(events: [ended, overnight, upcoming, tomorrow])

            #expect(agenda.events.map(\.id) == [overnight.id, upcoming.id])
            #expect(agenda.featuredEvent?.id == overnight.id)
            #expect(agenda.featuredEventIsOngoing)
        }

        @Test
        func appliesEventFilters() {
            let googleEvent = event(
                id: "google",
                platform: CalendarEventPlatform.googleCalendar,
                icalUid: "shared",
                start: 3600,
                end: 7200
            )
            let declined = event(id: "declined", start: 7200, end: 10800, isDeclined: true)

            let agenda = MenuBarCalendarAgenda(
                events: [googleEvent, declined],
                filter: CalendarEventFilter(includesDeclinedEvents: false),
                now: now,
                calendar: calendar
            )

            #expect(agenda.events.map(\.id) == [googleEvent.id])
        }

        @Test
        func distinguishesEventsExcludedByFiltersFromAnEmptyCalendar() {
            let declined = event(id: "declined", start: 3600, end: 7200, isDeclined: true)

            let filteredAgenda = MenuBarCalendarAgenda(
                events: [declined],
                filter: CalendarEventFilter(includesDeclinedEvents: false),
                now: now,
                calendar: calendar
            )
            let emptyAgenda = agenda(events: [])

            #expect(filteredAgenda.events.isEmpty)
            #expect(filteredAgenda.hasEventsExcludedByFilter)
            #expect(!emptyAgenda.hasEventsExcludedByFilter)
        }

        @Test
        func prioritizesAttendingOngoingEventBeforeLaterUnconfirmedEvent() {
            let attending = event(id: "attending", start: -1800, end: 3600, isAttending: true)
            let laterUnconfirmed = event(id: "unconfirmed", start: -600, end: 1800)

            let agenda = agenda(events: [laterUnconfirmed, attending])

            #expect(agenda.featuredEvent?.id == attending.id)
            #expect(agenda.featuredEventIsOngoing)
        }

        @Test
        func prioritizesMostRecentlyStartedOngoingEventWithSameParticipationThenNextEvent() {
            let earlierOngoing = event(id: "earlier", start: -1800, end: 3600)
            let laterOngoing = event(id: "later", start: -600, end: 1800)
            let next = event(id: "next", start: 3600, end: 7200)

            let ongoingAgenda = agenda(events: [next, earlierOngoing, laterOngoing])
            let upcomingAgenda = agenda(events: [next])

            #expect(ongoingAgenda.featuredEvent?.id == laterOngoing.id)
            #expect(ongoingAgenda.featuredEventIsOngoing)
            #expect(upcomingAgenda.featuredEvent?.id == next.id)
            #expect(!upcomingAgenda.featuredEventIsOngoing)
        }

        @Test
        func keepsAllDayEventsInListButNotInMenuBarLabel() {
            let startOfDay = calendar.startOfDay(for: now)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)
                ?? startOfDay.addingTimeInterval(86400)
            let allDay = event(
                id: "all-day",
                startDate: startOfDay,
                endDate: endOfDay,
                isAllDay: true
            )

            let agenda = agenda(events: [allDay])

            #expect(agenda.events == [allDay])
            #expect(agenda.featuredEvent == nil)
        }

        @Test
        func usesNoEventsLabelWhenNoTimedEventIsAvailable() {
            let startOfDay = calendar.startOfDay(for: now)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)
                ?? startOfDay.addingTimeInterval(86400)
            let allDay = event(
                id: "all-day",
                startDate: startOfDay,
                endDate: endOfDay,
                isAllDay: true
            )
            let declined = event(id: "declined", start: 3600, end: 7200, isDeclined: true)
            let filteredAgenda = MenuBarCalendarAgenda(
                events: [declined],
                filter: CalendarEventFilter(includesDeclinedEvents: false),
                now: now,
                calendar: calendar
            )

            for emptyAgenda in [agenda(events: []), agenda(events: [allDay]), filteredAgenda] {
                #expect(emptyAgenda.labelText(showsTitle: true, showsCountdown: true, now: now) == L10n.menuBarNoEvents)
                #expect(emptyAgenda.accessibilityLabel(now: now) == L10n.menuBarNoEvents)
            }
        }

        @Test
        func keepsDahliaFallbackWhenAllCalendarLabelDetailsAreDisabled() {
            let upcoming = event(id: "upcoming", start: 3600, end: 7200)

            #expect(agenda(events: [upcoming]).labelText(showsTitle: false, showsCountdown: false, now: now) == nil)
            #expect(agenda(events: []).labelText(showsTitle: false, showsCountdown: false, now: now) == nil)
        }

        @Test
        func roundsCountdownUpAndHonorsLabelSettings() {
            let upcoming = event(id: "upcoming", title: "Planning", start: 3601, end: 7200)
            let agenda = agenda(events: [upcoming])

            #expect(MenuBarCalendarAgenda.remainingMinutes(from: now, to: upcoming.startDate) == 61)
            #expect(agenda.labelText(showsTitle: true, showsCountdown: false, now: now) == "Planning")
            #expect(agenda.labelText(showsTitle: false, showsCountdown: false, now: now) == nil)
            #expect(agenda.labelText(showsTitle: false, showsCountdown: true, now: now)?.isEmpty == false)
            #expect(agenda.labelText(showsTitle: true, showsCountdown: true, now: now)?.contains("Planning") == true)
        }

        @Test
        func truncatesLongMenuBarTitlesWithoutTruncatingAccessibilityText() {
            let title = "Office Hours for Japan PS/DSA/Training [Weekly]"
            let upcoming = event(id: "upcoming", title: title, start: 3600, end: 7200)
            let agenda = agenda(events: [upcoming])

            #expect(agenda.labelText(showsTitle: true, showsCountdown: false, now: now) == "Office Hours for Japan P…")
            #expect(agenda.accessibilityLabel(now: now)?.hasPrefix(title) == true)
        }

        @Test
        func usesSoonTextForEventsStartingOrEndingInLessThanOneMinute() {
            let startingSoon = event(id: "starting", start: 59, end: 3600)
            let endingSoon = event(id: "ending", start: -3600, end: 59)

            #expect(agenda(events: [startingSoon]).countdownText(now: now) == L10n.menuBarStartingSoon)
            #expect(agenda(events: [endingSoon]).countdownText(now: now) == L10n.menuBarEndingSoon)
        }

        private func agenda(events: [CalendarEvent]) -> MenuBarCalendarAgenda {
            MenuBarCalendarAgenda(
                events: events,
                filter: CalendarEventFilter(includesAllDayEvents: true),
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
            isDeclined: Bool = false,
            isAttending: Bool = false
        ) -> CalendarEvent {
            event(
                id: id,
                title: title,
                platform: platform,
                icalUid: icalUid,
                startDate: now.addingTimeInterval(start),
                endDate: now.addingTimeInterval(end),
                isAllDay: isAllDay,
                isDeclined: isDeclined,
                isAttending: isAttending
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
            isDeclined: Bool = false,
            isAttending: Bool = false
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
                hasOtherAttendees: true,
                isDeclined: isDeclined,
                isAttending: isAttending,
                conferenceURI: URL(string: "https://meet.example.com/\(id)")
            )
        }
    }
#endif
