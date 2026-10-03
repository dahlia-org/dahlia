import Combine
import DahliaMeetingAccess
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CalendarSourceCoordinatorTests {
        @Test
        func refreshesOnlyEnabledSourcesAndAggregatesTheirEvents() async {
            let googleEvent = event(id: "google", platform: CalendarEventPlatform.googleCalendar, icalUid: "shared")
            let macEvent = event(id: "mac", platform: CalendarEventPlatform.macOSCalendar)
            let duplicateMacEvent = event(id: "mac-duplicate", platform: CalendarEventPlatform.macOSCalendar, icalUid: "shared")
            let googleStore = FakeCalendarEventSourceStore(source: .google, events: [googleEvent])
            let macStore = FakeCalendarEventSourceStore(source: .macOS, events: [duplicateMacEvent, macEvent])
            let coordinator = CalendarSourceCoordinator(stores: [googleStore, macStore])

            await coordinator.refreshEnabledSources([.google])

            #expect(googleStore.refreshCallCount == 1)
            #expect(macStore.refreshCallCount == 0)
            #expect(coordinator.events(for: [.google]) == [googleEvent])
            #expect(coordinator.events(for: [.google, .macOS]) == [googleEvent, macEvent])
        }

        @Test
        func updatesOnlyWhenASourcePublishesChangedEvents() {
            let originalEvent = event(id: "original", platform: CalendarEventPlatform.googleCalendar)
            let updatedEvent = event(id: "updated", platform: CalendarEventPlatform.googleCalendar)
            let store = FakeCalendarEventSourceStore(source: .google, events: [originalEvent])
            let coordinator = CalendarSourceCoordinator(stores: [store])
            var publicationCount = 0
            let cancellable = coordinator.$eventsBySource.dropFirst().sink { _ in publicationCount += 1 }

            store.replaceEvents([originalEvent])
            store.replaceEvents([updatedEvent])

            #expect(publicationCount == 1)
            #expect(coordinator.events(for: [.google]) == [updatedEvent])
            withExtendedLifetime(cancellable) {}
        }

        @Test
        func refreshesEnabledSourcesConcurrently() async {
            let blockedStore = FakeCalendarEventSourceStore(source: .google, events: [], blocksRefresh: true)
            let otherStore = FakeCalendarEventSourceStore(source: .macOS, events: [])
            let coordinator = CalendarSourceCoordinator(stores: [blockedStore, otherStore])

            let refresh = Task { await coordinator.refreshEnabledSources([.google, .macOS]) }
            await blockedStore.waitUntilRefreshStarts()
            await otherStore.waitUntilRefreshStarts()

            #expect(otherStore.refreshCallCount == 1)
            blockedStore.resumeRefresh()
            await refresh.value
        }

        @Test
        func tracksLoadedStateWithoutAnEventChange() {
            let store = FakeCalendarEventSourceStore(source: .google, events: [], isLoaded: false)
            let coordinator = CalendarSourceCoordinator(stores: [store])
            var publicationCount = 0
            let cancellable = coordinator.$loadedSources.dropFirst().sink { _ in publicationCount += 1 }

            store.setLoaded(true)

            #expect(coordinator.loadedSources == [.google])
            #expect(publicationCount == 1)
            withExtendedLifetime(cancellable) {}
        }

        @Test
        func publishedRefreshUsesAuthoritativeSourceAndQueuesOnlyLinkedOwners() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop", createdAt: .now
            )
            var ownerRecord = WorkspaceRecord(id: .v7(), path: nil, name: "Owner", createdAt: .now, lastOpenedAt: .now)
            ownerRecord.accountConnectionId = connection.id
            if ownerRecord.syncRole == nil { ownerRecord.syncRole = "admin" }
            if ownerRecord.organizationId == nil { ownerRecord.organizationId = .v7() }
            ownerRecord.syncConfirmedConnectionId = connection.id
            let owner = ownerRecord
            let local = WorkspaceRecord(id: .v7(), path: nil, name: "Local", createdAt: .now, lastOpenedAt: .now)
            var memberRecord = WorkspaceRecord(id: .v7(), path: nil, name: "Member", createdAt: .now, lastOpenedAt: .now)
            memberRecord.accountConnectionId = connection.id
            if memberRecord.syncRole == nil { memberRecord.syncRole = "admin" }
            if memberRecord.organizationId == nil { memberRecord.organizationId = .v7() }
            memberRecord.syncConfirmedConnectionId = connection.id
            memberRecord.syncRole = "viewer"
            let member = memberRecord
            let ownerMeeting = UUID.v7(), localMeeting = UUID.v7(), memberMeeting = UUID.v7()
            let attendee = CalendarParticipant(
                email: "person@example.com", displayName: "Person", kind: .person, isCurrentUser: false
            )
            let updatedAttendee = CalendarParticipant(
                email: "updated@example.com", displayName: "Updated", kind: .person, isCurrentUser: false
            )
            let original = event(
                id: "linked", platform: CalendarEventPlatform.googleCalendar, icalUid: "linked", participants: [attendee]
            )
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try owner.insert(db)
                try local.insert(db)
                try member.insert(db)
                try CalendarEventRecord.upsert(event: original, now: .now, in: db)
                for (id, workspace) in [(ownerMeeting, owner), (localMeeting, local), (memberMeeting, member)] {
                    try MeetingRecord(
                        id: id,
                        workspaceId: workspace.id,
                        name: workspace.name,
                        createdAt: .now,
                        updatedAt: .now,
                        calendarEventIcalUid: "linked",
                        calendarEventRecurrenceId: ""
                    ).insert(db)
                }
            }
            let googleStore = FakeCalendarEventSourceStore(source: .google, events: [original])
            let macStore = FakeCalendarEventSourceStore(
                source: .macOS,
                events: [event(
                    id: "mac-linked",
                    platform: CalendarEventPlatform.macOSCalendar,
                    icalUid: "linked",
                    participants: [attendee]
                )]
            )
            let coordinator = CalendarSourceCoordinator(stores: [googleStore, macStore], dbQueue: database.dbQueue)
            await coordinator.refreshEnabledSources([.google, .macOS])

            googleStore.replaceEvents([
                event(
                    id: "linked",
                    platform: CalendarEventPlatform.googleCalendar,
                    icalUid: "linked"
                ),
                event(
                    id: "linked-copy",
                    platform: CalendarEventPlatform.googleCalendar,
                    icalUid: "linked",
                    participants: [updatedAttendee]
                ),
                event(id: "unlinked", platform: CalendarEventPlatform.googleCalendar, icalUid: "unlinked"),
            ])
            await coordinator.waitForPersistence()

            try await database.dbQueue.read { db in
                let linked = try #require(try CalendarEventRecord.fetch(
                    key: CalendarEventKey(icalUid: "linked", recurrenceId: ""), in: db
                ))
                #expect(linked.attendees == [
                    CalendarAttendeeSnapshot(email: "updated@example.com", displayName: "Updated"),
                ])
                #expect(try CalendarEventRecord.fetch(
                    key: CalendarEventKey(icalUid: "unlinked", recurrenceId: ""), in: db
                ) == nil)
                #expect(try MeetingCalendarSync.fetch(meetingId: localMeeting, in: db)?.calendarEvent?.attendees == linked.attendees)
                #expect(try MeetingCalendarSync.fetch(meetingId: memberMeeting, in: db) == nil)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") == 1)
            }
            googleStore.replaceEvents([
                event(
                    id: "linked-copy",
                    platform: CalendarEventPlatform.googleCalendar,
                    icalUid: "linked",
                    participants: [updatedAttendee]
                ),
                event(id: "linked", platform: CalendarEventPlatform.googleCalendar, icalUid: "linked"),
            ])
            await coordinator.waitForPersistence()
            try await database.dbQueue.read { db in
                let linked = try #require(try CalendarEventRecord.fetch(
                    key: CalendarEventKey(icalUid: "linked", recurrenceId: ""), in: db
                ))
                #expect(linked.attendees.map(\.email) == ["updated@example.com"])
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") == 1)
            }
            let queued = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(queued.workspaceId == owner.id)
            #expect(queued.operations.map(\.entityId) == [ownerMeeting])
        }

        private func event(
            id: String,
            platform: String,
            icalUid: String? = nil,
            participants: [CalendarParticipant] = []
        ) -> CalendarEvent {
            CalendarEvent(
                id: id,
                calendarID: "calendar",
                calendarName: "Calendar",
                calendarColorHex: nil,
                platform: platform,
                platformId: id,
                title: id,
                description: "",
                icalUid: icalUid,
                startDate: Date(timeIntervalSince1970: 1_776_387_600),
                endDate: Date(timeIntervalSince1970: 1_776_391_200),
                isAllDay: false,
                participants: participants,
                conferenceURI: nil
            )
        }
    }

    @MainActor
    private final class FakeCalendarEventSourceStore: CalendarEventSourceStore {
        let source: CalendarSource
        @Published private(set) var upcomingEvents: [CalendarEvent]
        @Published private(set) var isLoaded: Bool
        private(set) var refreshCallCount = 0
        private let blocksRefresh: Bool
        private var refreshStartWaiter: CheckedContinuation<Void, Never>?
        private var refreshContinuation: CheckedContinuation<Void, Never>?

        var upcomingEventsPublisher: AnyPublisher<[CalendarEvent], Never> { $upcomingEvents.eraseToAnyPublisher() }
        var statePublisher: AnyPublisher<Bool, Never> { $isLoaded.eraseToAnyPublisher() }

        init(source: CalendarSource, events: [CalendarEvent], isLoaded: Bool = true, blocksRefresh: Bool = false) {
            self.source = source
            upcomingEvents = events
            self.isLoaded = isLoaded
            self.blocksRefresh = blocksRefresh
        }

        func refreshIfNeeded(force _: Bool) async {
            refreshCallCount += 1
            refreshStartWaiter?.resume()
            refreshStartWaiter = nil
            if blocksRefresh {
                await withCheckedContinuation { refreshContinuation = $0 }
            }
        }

        func replaceEvents(_ events: [CalendarEvent]) {
            guard upcomingEvents != events else { return }
            upcomingEvents = events
        }

        func setLoaded(_ isLoaded: Bool) {
            self.isLoaded = isLoaded
        }

        func waitUntilRefreshStarts() async {
            guard refreshCallCount == 0 else { return }
            await withCheckedContinuation { refreshStartWaiter = $0 }
        }

        func resumeRefresh() {
            refreshContinuation?.resume()
            refreshContinuation = nil
        }
    }
#endif
