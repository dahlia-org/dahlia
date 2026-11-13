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
            #expect(!filter.includes(makeEvent(isAttending: false)))
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

        /// Each account reads its own sources, then the app-wide choice saved before sources became per account.
        @Test
        func calendarSourcesArePerAccountAndInheritTheAppWideChoice() throws {
            let suiteName = "CalendarEventFilterTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let databricks = CodexRuntimeProvider.databricks(connectionID: UUID())

            #expect(AppSettings.enabledCalendarSources(for: .local, in: defaults) == CalendarSource.defaultEnabledSources)
            defaults.set("macOS", forKey: "calendarSource")
            #expect(AppSettings.enabledCalendarSources(for: .local, in: defaults) == [.macOS])
            defaults.set("[\"google\",\"macOS\"]", forKey: CalendarSource.enabledSourcesUserDefaultsKey)
            #expect(AppSettings.enabledCalendarSources(for: databricks, in: defaults) == [.google, .macOS])
            defaults.set("[\"google\"]", forKey: CalendarSource.enabledSourcesUserDefaultsKey(for: databricks))

            #expect(AppSettings.enabledCalendarSources(for: databricks, in: defaults) == [.google])
            #expect(AppSettings.enabledCalendarSources(for: .local, in: defaults) == [.google, .macOS])
        }

        @Test
        func includesOptionalEventTypesWhenEnabled() {
            #expect(CalendarEventFilter(includesAllDayEvents: true).includes(makeEvent(isAllDay: true)))
            #expect(CalendarEventFilter(includesEventsWithoutOtherAttendees: true)
                .includes(makeEvent(hasOtherAttendees: false)))
            #expect(CalendarEventFilter(includesEventsWithoutConferenceURI: true)
                .includes(makeEvent(conferenceURI: nil)))
            #expect(CalendarEventFilter(includesUnconfirmedEvents: true).includes(makeEvent(isAttending: false)))
            #expect(CalendarEventFilter(includesDeclinedEvents: true).includes(makeEvent(isDeclined: true)))
            #expect(CalendarEventFilter(includesOutOfOfficeEvents: true).includes(makeEvent(isOutOfOffice: true)))
        }

        @Test(arguments: [false, true], [false, true])
        func filtersUnconfirmedAndDeclinedEventsIndependently(
            includesUnconfirmed: Bool,
            includesDeclined: Bool
        ) {
            let filter = CalendarEventFilter(
                includesUnconfirmedEvents: includesUnconfirmed,
                includesDeclinedEvents: includesDeclined
            )

            #expect(filter.includes(makeEvent(isAttending: true)))
            #expect(filter.includes(makeEvent(isAttending: false)) == includesUnconfirmed)
            #expect(filter.includes(makeEvent(isDeclined: true)) == includesDeclined)
            #expect(!filter.includes(makeEvent(isAllDay: true, isAttending: true)))
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
            isAttending: Bool = true,
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
                isAttending: isAttending,
                isOutOfOffice: isOutOfOffice,
                conferenceURI: conferenceURI
            )
        }
    }
#endif
