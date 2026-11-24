import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CalendarAutoRecordingTests {
        @Test(arguments: [false, true])
        func legacyGoogleFallbackReservationsRetainOnlyTheKnownOriginalProvider(knownProvider: Bool) throws {
            let (defaults, suiteName) = try temporaryUserDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let original = UUID.v7()
            let other = UUID.v7()
            let providerID = "googleCalendar.\(original.uuidString)"
            let google = makeEvent(icalUid: nil)
            let mac = makeEvent(platform: CalendarEventPlatform.macOSCalendar, icalUid: nil)
            let shared = makeEvent(icalUid: "shared")
            let alreadyScoped = makeEvent(id: "scoped", icalUid: nil).scoped(to: "googleCalendar.\(other.uuidString)")
            let selections = [google, mac, shared, alreadyScoped].map(CalendarAutoRecordingSelection.init(event:))
            let encoded = try JSONEncoder().encode(selections)
            // Released source fallback IDs had no providerID field at all.
            var json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
            for index in 0 ..< 3 {
                var identity = try #require(json[index]["eventID"] as? [String: Any])
                identity.removeValue(forKey: "providerID")
                json[index]["eventID"] = identity
            }
            try defaults.set(JSONSerialization.data(withJSONObject: json), forKey: CalendarAutoRecordingStore.selectionsUserDefaultsKey)
            if knownProvider { defaults.set(original.uuidString, forKey: SingleAccountMigration.sourceKey) }
            GoogleCalendarProvider.save(.databricks(connectionID: other), defaults: defaults)
            let store = CalendarAutoRecordingStore(userDefaults: defaults)
            store.activateAfterAccountMigration()
            #expect(store.isEnabled(for: google.scoped(to: providerID)) == knownProvider)
            #expect(!store.isEnabled(for: google.scoped(to: "googleCalendar.\(other.uuidString)")))
            #expect(store.isEnabled(for: mac))
            #expect(store.isEnabled(for: shared))
            #expect(store.isEnabled(for: alreadyScoped))
            let reopened = CalendarAutoRecordingStore(userDefaults: defaults)
            #expect(reopened.selections == store.selections)
        }

        @Test
        func identifiesTheSameOccurrenceAcrossCalendarSources() {
            let startDate = Date(timeIntervalSince1970: 1_776_387_600)
            let googleEvent = makeEvent(
                platform: CalendarEventPlatform.googleCalendar,
                calendarID: "google",
                platformId: "google-event",
                recurrenceId: "20260417T003000Z",
                startDate: startDate
            )
            let macEvent = makeEvent(
                platform: CalendarEventPlatform.macOSCalendar,
                calendarID: "mac",
                platformId: "mac-event",
                recurrenceId: "20260417T003000Z",
                startDate: startDate
            )

            #expect(CalendarAutoRecordingEventID(event: googleEvent) == CalendarAutoRecordingEventID(event: macEvent))
        }

        @Test
        func keepsRecurringOccurrencesDistinct() {
            let first = makeEvent(recurrenceId: "20260417T003000Z")
            let second = makeEvent(recurrenceId: "20260424T003000Z")

            #expect(CalendarAutoRecordingEventID(event: first) != CalendarAutoRecordingEventID(event: second))
        }

        @Test
        func fallbackIdentityIncludesTheCalendarSource() {
            let first = makeEvent(calendarID: "primary", icalUid: nil)
            let second = makeEvent(calendarID: "shared", icalUid: nil)

            #expect(CalendarAutoRecordingEventID(event: first) != CalendarAutoRecordingEventID(event: second))
        }

        @Test
        func fallbackIdentitySurvivesAMacEventTimeChange() {
            let initial = makeEvent(
                platform: CalendarEventPlatform.macOSCalendar,
                platformId: "event-kit-id::1776387600",
                icalUid: nil
            )
            let moved = makeEvent(
                platform: CalendarEventPlatform.macOSCalendar,
                platformId: "event-kit-id::1776389400",
                icalUid: nil,
                startDate: initial.startDate.addingTimeInterval(1800)
            )

            #expect(CalendarAutoRecordingEventID(event: initial) == CalendarAutoRecordingEventID(event: moved))
        }

        @Test
        func persistsAndDisablesASelection() throws {
            let (defaults, suiteName) = try temporaryUserDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let event = makeEvent()
            let store = CalendarAutoRecordingStore(userDefaults: defaults)

            store.setEnabled(true, for: event)

            #expect(store.isEnabled(for: event))
            #expect(CalendarAutoRecordingStore(userDefaults: defaults).isEnabled(for: event))

            store.setEnabled(false, for: event)

            #expect(!store.isEnabled(for: event))
            #expect(defaults.data(forKey: CalendarAutoRecordingStore.selectionsUserDefaultsKey) == nil)
        }

        @Test
        func ignoresAllDayEvents() throws {
            let (defaults, suiteName) = try temporaryUserDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let store = CalendarAutoRecordingStore(userDefaults: defaults)
            let event = makeEvent(isAllDay: true)

            store.setEnabled(true, for: event)

            #expect(!store.isEnabled(for: event))
        }

        @Test
        func synchronizesChangedTimesAndPrunesEndedSelections() throws {
            let (defaults, suiteName) = try temporaryUserDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let initialStart = Date(timeIntervalSince1970: 1_776_387_600)
            let movedStart = initialStart.addingTimeInterval(1800)
            let store = CalendarAutoRecordingStore(userDefaults: defaults)
            store.setEnabled(true, for: makeEvent(startDate: initialStart))

            store.synchronize(
                with: [makeEvent(startDate: movedStart)],
                now: initialStart.addingTimeInterval(-60)
            )

            #expect(store.selections.first?.startDate == movedStart)

            store.synchronize(with: [], now: movedStart.addingTimeInterval(3601))

            #expect(store.selections.isEmpty)
        }

        @Test
        func plannerReturnsOngoingEventsAndTheNextFutureEvaluation() {
            let now = Date(timeIntervalSince1970: 1_776_387_600)
            let ongoing = makeEvent(id: "ongoing", startDate: now.addingTimeInterval(-300))
            let future = makeEvent(id: "future", startDate: now.addingTimeInterval(600))
            let selections = [ongoing, future].map(CalendarAutoRecordingSelection.init(event:))

            let dueEvents = CalendarAutoRecordingPlanner.dueEvents(
                events: [future, ongoing],
                selections: selections,
                now: now
            )
            let nextEvaluation = CalendarAutoRecordingPlanner.nextEvaluationDate(
                events: [future, ongoing],
                selections: selections,
                now: now
            )

            #expect(dueEvents.map(\.id) == [ongoing.id])
            #expect(nextEvaluation == future.startDate)
        }

        @Test
        func plannerOrdersSimultaneousEventsAndIgnoresEndedEvents() {
            let now = Date(timeIntervalSince1970: 1_776_387_600)
            let first = makeEvent(id: "a", icalUid: "a@example.com", startDate: now.addingTimeInterval(-60))
            let second = makeEvent(id: "b", icalUid: "b@example.com", startDate: now.addingTimeInterval(-60))
            let ended = makeEvent(
                id: "ended",
                icalUid: "ended@example.com",
                startDate: now.addingTimeInterval(-4000),
                duration: 3600
            )
            let events = [second, ended, first]

            let dueEvents = CalendarAutoRecordingPlanner.dueEvents(
                events: events,
                selections: events.map(CalendarAutoRecordingSelection.init(event:)),
                now: now
            )

            #expect(dueEvents.map(\.id) == [first.id, second.id])
        }

        @Test
        func missingEventWakesAtItsStoredEndForCleanup() {
            let now = Date(timeIntervalSince1970: 1_776_387_600)
            let event = makeEvent(startDate: now.addingTimeInterval(600))
            let selection = CalendarAutoRecordingSelection(event: event)

            let nextEvaluation = CalendarAutoRecordingPlanner.nextEvaluationDate(
                events: [],
                selections: [selection],
                now: now
            )

            #expect(nextEvaluation == event.endDate)
        }

        private func temporaryUserDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
            let suiteName = "CalendarAutoRecordingTests.\(UUID().uuidString)"
            return try (#require(UserDefaults(suiteName: suiteName)), suiteName)
        }

        private func makeEvent(
            id: String = "event",
            platform: String = CalendarEventPlatform.googleCalendar,
            calendarID: String = "calendar",
            platformId: String? = nil,
            icalUid: String? = "shared@example.com",
            recurrenceId: String = ICalendarRecurrenceID.singleEvent,
            startDate: Date = Date(timeIntervalSince1970: 1_776_387_600),
            duration: TimeInterval = 3600,
            isAllDay: Bool = false
        ) -> CalendarEvent {
            CalendarEvent(
                id: id,
                calendarID: calendarID,
                calendarName: "Work",
                calendarColorHex: nil,
                platform: platform,
                platformId: platformId ?? id,
                title: "Planning",
                description: "",
                icalUid: icalUid,
                recurrenceId: recurrenceId,
                startDate: startDate,
                endDate: startDate.addingTimeInterval(duration),
                isAllDay: isAllDay,
                conferenceURI: nil
            )
        }
    }
#endif
