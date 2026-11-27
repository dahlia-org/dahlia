#if canImport(Testing)
    import DahliaRuntimeSupport
    import EventKit
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct AgentCalendarInboxTests {
        private let now = Date(timeIntervalSince1970: 1_800_000_000)

        private func service() throws -> (AgentInboxService, String) {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let agent = try queue.write { try AgentRecord.insertForTest(in: $0) }
            let service = AgentInboxService(dbQueue: queue, agentID: agent.id)
            var source = AgentSourceRecord(
                id: UUID.v7().uuidString,
                agentID: agent.id,
                name: "Calendar",
                server: "calendar",
                instructions: "",
                intervalMinutes: 5,
                allowedSenders: "[]",
                cursor: nil,
                enabled: true,
                lastIntakeAt: nil,
                createdAt: now,
                updatedAt: now
            )
            source.kind = "calendar"
            source.leadHours = 24
            try service.saveSource(source)
            return (service, source.id)
        }

        private func event(_ id: String = "event", provider: String = "provider-a", start: Date? = nil, accepted: Bool = false) -> CalendarEvent {
            let start = start ?? now.addingTimeInterval(3600)
            return CalendarEvent(
                id: id,
                calendarID: "primary",
                calendarName: "Calendar",
                calendarColorHex: nil,
                platformId: id,
                title: "Meeting",
                description: "Untrusted description",
                icalUid: nil,
                startDate: start,
                endDate: start.addingTimeInterval(1800),
                isAllDay: false,
                isAttending: accepted,
                responseStatus: accepted ? .accepted : .tentative,
                conferenceURI: nil
            ).scoped(to: provider)
        }

        @Test func duplicateMovedDeletedAndStartedMeetingsReconcileEvenAfterTheSignalIsDue() throws {
            let (service, _) = try service()
            let original = event()
            try service.reconcileCalendar(.init(events: [original], successfulProviders: ["provider-a"]), now: now)
            try service.reconcileCalendar(.init(events: [original], successfulProviders: ["provider-a"]), now: now)
            let first = try #require(try service.inbox(now: now).events.first)
            #expect(try service.recentEvents().count == 1)
            let moved = event(start: now.addingTimeInterval(7200))
            try service.reconcileCalendar(.init(events: [moved], successfulProviders: ["provider-a"]), now: now)
            let second = try #require(try service.inbox(now: now).events.first)
            #expect(second.id != first.id && second.key != first.key)
            #expect(try service.recentEvents().count == 1)
            try service.reconcileCalendar(.init(events: [moved], successfulProviders: ["provider-a"]), now: moved.startDate)
            #expect(try service.recentEvents().isEmpty)
            try service.reconcileCalendar(.init(events: [original], successfulProviders: ["provider-a"]), now: now)
            try service.reconcileCalendar(.init(events: [], successfulProviders: ["provider-a"]), now: now)
            #expect(try service.recentEvents().isEmpty)
        }

        @Test func failedOrUnloadedProvidersKeepTheirPendingSignals() throws {
            let (service, _) = try service()
            try service.reconcileCalendar(.init(
                events: [event(), event("other", provider: "provider-b")],
                successfulProviders: ["provider-a", "provider-b"]
            ), now: now)
            try service.reconcileCalendar(.init(), now: now)
            #expect(try service.recentEvents().count == 2)
            try service.reconcileCalendar(.init(successfulProviders: ["provider-a"]), now: now)
            let remaining = try service.recentEvents()
            #expect(remaining.count == 1 && remaining.first?.ref?.contains("provider-b") == true)
        }

        @Test(arguments: [false, true])
        func deselectedProvidersCancelSignalsWhileFetchFailuresRetainThem(disabled: Bool) throws {
            let (service, _) = try service()
            let future = event(start: now.addingTimeInterval(26 * 3600))
            try service.reconcileCalendar(.init(events: [future], successfulProviders: ["provider-a"]), now: now)
            #expect(try service.recentEvents().count == 1)
            // The next tick may be after the signal became due, so selection must not depend on that timing.
            try service.reconcileCalendar(.init(selectedProviders: disabled ? [] : ["provider-a"]), now: now.addingTimeInterval(3 * 3600))
            #expect(try service.recentEvents().count == (disabled ? 0 : 1))
            #expect(try service.inbox(now: now.addingTimeInterval(3 * 3600)).events.count == (disabled ? 0 : 1))
        }

        @Test(arguments: [false, true], [false, true])
        func pausedSourcesRetainSelectedSignalsButHonorDeselection(disabled: Bool, anotherSourceEnabled: Bool) throws {
            let (service, _) = try service()
            let snapshot = AgentCalendarSnapshot(events: [event()], successfulProviders: ["provider-a"], selectedProviders: ["provider-a"])
            try service.reconcileCalendar(snapshot, now: now)
            let arrived = try #require(try service.inbox(now: now).events.first)
            var source = try #require(try service.sources().first)
            source.enabled = false
            try service.saveSource(source, now: now)
            if anotherSourceEnabled {
                var other = source
                other.id = UUID.v7().uuidString
                other.enabled = true
                try service.saveSource(other, now: now)
            }
            let paused = try #require(try service.sources().first { $0.id == source.id })
            try service.reconcileCalendar(.init(
                events: [event(), event("new")], successfulProviders: ["provider-a"],
                selectedProviders: disabled ? [] : ["provider-a"]
            ), now: now)
            let retained = try service.recentEvents().filter { $0.sourceID == source.id }
            #expect(retained.map(\.id) == (disabled ? [] : [arrived.id]))
            #expect(try service.sources().first { $0.id == source.id }?.lastIntakeAt == paused.lastIntakeAt)
        }

        @Test(arguments: [false, true])
        func noSelectedCalendarCancelsThePendingDailySignal(paused: Bool) throws {
            let (service, _) = try service()
            var source = try #require(try service.sources().first)
            source.dailyAt = "08:00"
            try service.saveSource(source)
            try service.reconcileCalendar(.init(successfulProviders: ["provider-a"]), now: now)
            #expect(try service.recentEvents().contains { $0.key?.hasPrefix("daily:") == true })
            if paused {
                source.enabled = false
                try service.saveSource(source, now: now.addingTimeInterval(86400))
            }
            try service.reconcileCalendar(.init(selectedProviders: []), now: paused ? now.addingTimeInterval(86400) : now)
            #expect(try service.recentEvents().isEmpty)
        }

        @Test func dailyAgendaIsUniqueAndScheduleEditsUpdateOnlyUnhandledSignals() throws {
            let (service, _) = try service()
            var source = try #require(try service.sources().first)
            source.dailyAt = "08:00"
            source.leadHours = nil
            try service.saveSource(source)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            let snapshot = AgentCalendarSnapshot(successfulProviders: ["provider-a"])
            try service.reconcileCalendar(snapshot, now: now, calendar: calendar)
            try service.reconcileCalendar(snapshot, now: now, calendar: calendar)
            let first = try #require(try service.recentEvents().first)
            #expect(calendar.component(.hour, from: first.occurredAt) == 8)
            source = try #require(try service.sources().first)
            source.dailyAt = "09:00"
            try service.saveSource(source)
            try service.reconcileCalendar(snapshot, now: now, calendar: calendar)
            #expect(try service.recentEvents().count == 1)
            #expect(try service.recentEvents().first.map { calendar.component(.hour, from: $0.occurredAt) } == 9)
            try service.close(eventIDs: [first.id])
            try service.reconcileCalendar(snapshot, now: now, calendar: calendar)
            #expect(try service.recentEvents().first?.handledAt != nil)
        }

        /// A weekly check alone is a valid schedule. It signals once, only on its weekday, and turning it off cancels it.
        @Test func weeklyAgendaAloneSignalsOnceOnItsWeekday() throws {
            let (service, _) = try service()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            var source = try #require(try service.sources().first)
            source.leadHours = nil
            source.sourceOptions.weeklyAt = "09:00"
            source.sourceOptions.weekday = calendar.component(.weekday, from: now) % 7 + 1
            try service.saveSource(source, now: now)
            let snapshot = AgentCalendarSnapshot(successfulProviders: ["provider-a"])
            try service.reconcileCalendar(snapshot, now: now, calendar: calendar)
            #expect(try service.recentEvents().isEmpty)

            source = try #require(try service.sources().first)
            source.sourceOptions.weekday = calendar.component(.weekday, from: now)
            try service.saveSource(source, now: now)
            try service.reconcileCalendar(snapshot, now: now, calendar: calendar)
            try service.reconcileCalendar(snapshot, now: now.addingTimeInterval(60), calendar: calendar)
            let weekly = try #require(try service.recentEvents().first)
            #expect(try service.recentEvents().count == 1)
            #expect(weekly.key == "weekly:2027-W02" && calendar.component(.hour, from: weekly.occurredAt) == 9)
            #expect(weekly.note == AgentSourcePrompt.weeklyNote(source))

            source = try #require(try service.sources().first)
            source.sourceOptions.weeklyAt = nil
            source.dailyAt = "08:00"
            try service.saveSource(source, now: now)
            #expect(try !service.recentEvents().contains { $0.key?.hasPrefix("weekly:") == true })
            source.dailyAt = nil
            #expect(throws: AgentInboxService.Failure.self) { try service.saveSource(source, now: now) }
            source.sourceOptions.weeklyAt = "09:00"
            source.sourceOptions.weekday = 8
            #expect(throws: AgentInboxService.Failure.self) { try service.saveSource(source, now: now) }
        }

        @Test(arguments: [false, true])
        func unrelatedEditsKeepFutureWeeklySignalsAcrossFetchFailures(changeFilter: Bool) throws {
            let (service, _) = try service()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            var source = try #require(try service.sources().first)
            source.leadHours = nil
            source.sourceOptions = .init(weeklyAt: "09:00", weekday: calendar.component(.weekday, from: now))
            try service.saveSource(source, now: now)
            try service.reconcileCalendar(.init(successfulProviders: ["provider-a"]), now: now, calendar: calendar)
            let original = try #require(try service.recentEvents().first)
            #expect(original.occurredAt > now)

            if changeFilter { source.sourceOptions.acceptedOnly = true } else { source.name = "Renamed" }
            try service.saveSource(source, now: now.addingTimeInterval(60))
            let failed = AgentCalendarSnapshot(selectedProviders: ["provider-a"])
            for at in [now.addingTimeInterval(120), now.addingTimeInterval(86400)] {
                try service.reconcileCalendar(failed, now: at, calendar: calendar)
                let retained = try #require(try service.recentEvents().first)
                #expect(retained.id == original.id && retained.occurredAt == original.occurredAt && retained.ref == original.ref)
                #expect(retained.note == AgentSourcePrompt.weeklyNote(source))
            }
        }

        @Test(arguments: [false, true])
        func changingWeeklyScheduleCancelsItsFutureSignal(changeWeekday: Bool) throws {
            let (service, _) = try service()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            var source = try #require(try service.sources().first)
            source.leadHours = nil
            source.sourceOptions = .init(weeklyAt: "09:00", weekday: calendar.component(.weekday, from: now))
            try service.saveSource(source, now: now)
            try service.reconcileCalendar(.init(successfulProviders: ["provider-a"]), now: now, calendar: calendar)
            #expect(try service.recentEvents().count == 1)
            if changeWeekday {
                source.sourceOptions.weekday = calendar.component(.weekday, from: now) % 7 + 1
            } else {
                source.sourceOptions.weeklyAt = "10:00"
            }
            try service.saveSource(source, now: now)
            #expect(try service.recentEvents().isEmpty)
        }

        /// Turning on accepted-only rewrites waiting agenda notes and drops waiting signals for meetings not accepted.
        @Test func acceptedOnlyRewritesWaitingSignalsAndKeepsDecidedOnes() throws {
            let (service, _) = try service()
            var source = try #require(try service.sources().first)
            source.dailyAt = "00:00"
            try service.saveSource(source, now: now)
            let accepted = event("accepted", accepted: true), tentative = event("tentative")
            let decided = event("decided", start: now.addingTimeInterval(7200))
            let snapshot = AgentCalendarSnapshot(events: [accepted, tentative, decided], successfulProviders: ["provider-a"])
            try service.reconcileCalendar(snapshot, now: now)
            let decidedSignal = try #require(try service.recentEvents().first { $0.key?.contains("decided") == true })
            try service.close(eventIDs: [decidedSignal.id])
            #expect(try service.recentEvents().count == 4)

            source = try #require(try service.sources().first)
            source.sourceOptions.acceptedOnly = true
            try service.saveSource(source, now: now)
            try service.reconcileCalendar(snapshot, now: now)
            let events = try service.recentEvents()
            #expect(events.count == 3)
            #expect(events.contains { $0.key?.contains("accepted") == true } && !events.contains { $0.key?.contains("tentative") == true })
            let daily = try #require(events.first { $0.key?.hasPrefix("daily:") == true })
            #expect(daily.note == AgentSourcePrompt.dailyNote(source) && daily.note.hasSuffix(L10n.agentCalendarAcceptedOnlyNote))
            #expect(events.first { $0.id == decidedSignal.id }?.handledAt != nil)
        }

        @Test(arguments: [false, true])
        func savingOptionsUpdatesOlderPendingAgendasWithoutAProviderRefresh(paused: Bool) throws {
            let (service, _) = try service()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
            let previousDay = now.addingTimeInterval(-86400)
            var source = try #require(try service.sources().first)
            source.dailyAt = "00:00"
            source.leadHours = nil
            source.sourceOptions = .init(weeklyAt: "00:00", weekday: calendar.component(.weekday, from: previousDay))
            try service.saveSource(source, now: previousDay)
            let snapshot = AgentCalendarSnapshot(successfulProviders: ["provider-a"])
            try service.reconcileCalendar(snapshot, now: previousDay, calendar: calendar)
            #expect(try service.recentEvents().count == 2)
            try service.reconcileCalendar(snapshot, now: now, calendar: calendar)
            let decided = try #require(try service.recentEvents().first { $0.createdAt == now })
            try service.close(eventIDs: [decided.id])
            let original = try service.recentEvents()
            #expect(original.count == 3)

            for acceptedOnly in [true, false] {
                source.sourceOptions.acceptedOnly = acceptedOnly
                source.enabled = !paused
                try service.saveSource(source, now: now)
                try service.reconcileCalendar(.init(selectedProviders: ["provider-a"]), now: now, calendar: calendar)
                let updated = try service.recentEvents()
                #expect(updated.count == original.count)
                for before in original {
                    let after = try #require(updated.first { $0.id == before.id })
                    let note = before.key?.hasPrefix("weekly:") == true
                        ? AgentSourcePrompt.weeklyNote(source) : AgentSourcePrompt.dailyNote(source)
                    #expect(after.note == (before.handledAt == nil ? note : before.note))
                    #expect(after.occurredAt == before.occurredAt && after.ref == before.ref && after.handledAt == before.handledAt)
                }
            }
        }

        @Test(arguments: ["", ", \"attendees\": []"])
        func acceptedOnlyKeepsEventsWithoutAttendees(_ attendeesJSON: String) async throws {
            let (service, _) = try service()
            var source = try #require(try service.sources().first)
            source.sourceOptions.acceptedOnly = true
            try service.saveSource(source, now: now)
            let data = Data("""
            {
              "items": [{
                "id": "solo",
                "start": { "dateTime": "\(now.addingTimeInterval(3600).ISO8601Format())" },
                "end": { "dateTime": "\(now.addingTimeInterval(7200).ISO8601Format())" }
                \(attendeesJSON)
              }]
            }
            """.utf8)
            let response = try JSONDecoder().decode(GoogleCalendarAPIClient.EventListResponse.self, from: data)
            let payload = try #require(response.items.first)
            let event = try await MainActor.run {
                try #require(try GoogleCalendarAPIClient.makeEvent(
                    from: payload, calendarItem: CalendarListItem(id: "primary", title: "Primary", colorHex: nil, isPrimary: true)
                )).scoped(to: "provider-a")
            }
            let snapshot = AgentCalendarSnapshot(events: [event], successfulProviders: ["provider-a"])
            try service.reconcileCalendar(snapshot, now: now)
            try service.reconcileCalendar(snapshot, now: now)
            #expect(try service.recentEvents().count == 1)
            #expect(try service.inbox(now: now).events.first?.key?.hasPrefix("meeting:") == true)
        }

        @Test func calendarLeadMustFitInsideTheFetchedHorizon() throws {
            let (service, _) = try service()
            var source = try #require(try service.sources().first)
            for hours in [0.0, -1, 168, Double.infinity, Double.nan] {
                source.leadHours = hours
                #expect(throws: AgentInboxService.Failure.self) { try service.saveSource(source) }
            }
            source.leadHours = 167
            try service.saveSource(source)
            #expect(try service.dueSources(now: now).isEmpty)
        }

        @Test func disablingACalendarSourceCancelsItsFutureSignals() throws {
            let (service, _) = try service()
            let meeting = event(start: now.addingTimeInterval(2 * 86400))
            try service.reconcileCalendar(.init(events: [meeting], successfulProviders: ["provider-a"]), now: now)
            #expect(try service.recentEvents().count == 1)
            var source = try #require(try service.sources().first)
            source.enabled = false
            try service.saveSource(source, now: now)
            #expect(try service.recentEvents().isEmpty)
        }

        @Test func disablingMeetingSignalsKeepsArrivedSignalsUntilTheMeetingChanges() throws {
            let (service, _) = try service()
            var source = try #require(try service.sources().first)
            source.dailyAt = "00:00"
            try service.saveSource(source, now: now)
            let due = event("due"), future = event("future", start: now.addingTimeInterval(2 * 86400))
            let snapshot = AgentCalendarSnapshot(events: [due, future], successfulProviders: ["provider-a"])
            try service.reconcileCalendar(snapshot, now: now)
            let arrived = try #require(try service.inbox(now: now).events.first { $0.key?.hasPrefix("meeting:") == true })
            let pending = try #require(try service.recentEvents().first { $0.occurredAt > now && $0.key?.hasPrefix("meeting:") == true })

            source.leadHours = nil
            try service.saveSource(source, now: now)
            try service.reconcileCalendar(snapshot, now: now)
            #expect(try service.inbox(now: now).events.contains { $0.id == arrived.id })
            #expect(try !service.recentEvents().contains { $0.id == pending.id })

            // A disabled notification still discards obsolete signals when the meeting itself disappears.
            try service.reconcileCalendar(.init(successfulProviders: ["provider-a"]), now: now)
            #expect(try !service.recentEvents().contains { $0.id == arrived.id })
        }

        @Test func remindersAreHiddenUntilDueAndCanBeCancelled() throws {
            let (service, _) = try service()
            let id = try service.remind(at: now.addingTimeInterval(60), note: "Follow up", now: now)
            #expect(try !service.hasUndecidedEvents(now: now))
            #expect(try service.hasUndecidedEvents(now: now.addingTimeInterval(60)))
            try service.close(eventIDs: [id])
            #expect(try !service.hasUndecidedEvents(now: now.addingTimeInterval(60)))
            #expect(throws: AgentInboxService.Failure.self) { try service.remind(at: now, note: "Too late", now: now) }
            #expect(throws: AgentInboxService.Failure.self) { try service.remind(at: now.addingTimeInterval(60), note: "", now: now) }
        }

        @Test func calendarReadUsesTheInjectedSnapshotAndReportsResponseStatus() async throws {
            let snapshot = AgentCalendarSnapshot(events: [event()], successfulProviders: ["provider-a"])
            let chat = PiChatService(calendarSnapshot: { snapshot })
            let result = try await chat.calendarRead([:], now: now)
            let rows = result.objectValue?["events"]?.arrayValue
            #expect(rows?.count == 1 && rows?.first?.objectValue?["response_status"] == .string("tentative"))
            #expect(PiExecutionProfile.bot.allows("calendar_read") && PiExecutionProfile.bot.allows("remind"))
            #expect(!PiExecutionProfile.intake.allows("calendar_read") && !PiExecutionProfile.scheduled.allows("remind"))
        }

        @Test @MainActor func nativeCalendarSelectionDoesNotReserveAnMCPServerName() {
            let model = DahliaBotPanelModel()
            model.servers = ["calendar"]
            model.services = ["calendar": "system.ai.gmail"]
            model.edit(nil)
            model.choose(server: "calendar")
            #expect(model.draft?.kind == "mcp" && model.draft?.server == "calendar")
            model.chooseCalendar()
            #expect(model.draft?.kind == "calendar" && model.draft?.server.isEmpty == true)
            model.choose(server: "calendar")
            #expect(model.draft?.kind == "mcp" && model.draft?.server == "calendar")
        }

        @Test @MainActor func platformStatusesPreserveUnansweredAndTentativeInvitations() {
            #expect(EventKitMacCalendarEventStore.responseStatus(.pending) == .pending)
            #expect(EventKitMacCalendarEventStore.responseStatus(.tentative) == .tentative)
            #expect(EventKitMacCalendarEventStore.responseStatus(.accepted) == .accepted)
            #expect(EventKitMacCalendarEventStore.responseStatus(.declined) == .declined)
            #expect(EventKitMacCalendarEventStore.responseStatus(nil) == .unknown)
            #expect(CalendarEvent.ResponseStatus(google: "needsAction") == .pending)
            #expect(CalendarEvent.ResponseStatus(google: "tentative") == .tentative)
        }
    }
#endif
