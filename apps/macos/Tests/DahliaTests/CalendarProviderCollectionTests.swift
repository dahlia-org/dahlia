import Combine
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CalendarProviderCollectionTests {
        @Test
        func multipleGoogleAndDatabricksConnectionsHaveIndependentSwitchesAndSurviveReload() async {
            let catalog = [connection(google: true), connection(google: true), connection(), connection()]
            let defaults = defaults(enabling: catalog)
            let stores = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, Store(events: [event($0.id).scoped(to: $0.id)])) })
            let collection = CalendarProviderCollection(
                defaults: defaults, observesChanges: false, loadConnections: { catalog }, makeStore: { stores[$0.id]! }
            )
            await collection.reloadConnections()
            await collection.refreshIfNeeded(force: true)
            #expect(collection.upcomingEvents.count == 4)
            #expect(stores.values.allSatisfy { $0.refreshCount == 1 })
            #expect(collection.isLoaded)

            let disabled = catalog[0].id
            collection.setEnabled(false, for: disabled)
            #expect(collection.enabledIDs == Set(catalog.dropFirst().map(\.id)))
            #expect(collection.upcomingEvents.count == 3)
            #expect(stores[disabled]?.active == false)
            let othersAreActive = stores.filter { $0.key != disabled }.values.allSatisfy(\.active)
            #expect(othersAreActive)
            await collection.reloadConnections()
            #expect(collection.enabledIDs.count == 3)
            #expect(collection.upcomingEvents.count == 3)
            #expect(defaults.string(forKey: GoogleCalendarProvider.userDefaultsKey) == nil)
            let reopened = CalendarProviderCollection(
                defaults: defaults,
                observesChanges: false,
                loadConnections: { catalog },
                makeStore: { stores[$0.id]! }
            )
            #expect(reopened.enabledIDs == collection.enabledIDs)
        }

        @Test
        func aBlockedOrFailedConnectionDoesNotHideHealthyEventsOrPreventPersistence() async throws {
            let catalog = [connection(), connection()]
            let healthy = event("healthy")
            let stale = event("stale")
            let blocked = Store(events: [stale], state: .loading, blocksRefresh: true)
            let ready = Store(events: [healthy])
            let database = try AppDatabaseManager(path: ":memory:")
            try await database.dbQueue.write { db in
                let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Local", createdAt: .now, lastOpenedAt: .now)
                try workspace.insert(db)
                for item in [healthy, stale] {
                    try CalendarEventRecord.upsert(event: item, now: .now, in: db)
                    try MeetingRecord(
                        id: .v7(), workspaceId: workspace.id, name: item.title, createdAt: .now, updatedAt: .now,
                        calendarEventIcalUid: item.icalUid, calendarEventRecurrenceId: ""
                    ).insert(db)
                }
            }
            let collection = CalendarProviderCollection(
                defaults: defaults(enabling: catalog), observesChanges: false, loadConnections: { catalog },
                makeStore: { $0.id == catalog[0].id ? blocked : ready }
            )
            await collection.reloadConnections()
            let coordinator = CalendarSourceCoordinator(stores: [collection], dbQueue: database.dbQueue)
            let refresh = Task { await coordinator.refreshEnabledSources([.google]) }
            await blocked.waitUntilStarted()
            await ready.waitUntilStarted()
            var readinessPublications = 0
            let token = coordinator.$loadedSources.dropFirst().sink { _ in readinessPublications += 1 }
            ready.replace([event("healthy", title: "fresh")], state: .loaded)
            #expect(readinessPublications > 0)
            withExtendedLifetime(token) {}
            #expect(coordinator.events(for: [.google], requiringLoadedSources: true).map(\.title) == ["fresh"])
            #expect(!collection.isLoaded)
            await coordinator.waitForPersistence()
            try await database.dbQueue.read { db in
                let healthyRecord = try CalendarEventRecord.fetch(key: CalendarEventKey(icalUid: "healthy", recurrenceId: ""), in: db)
                let staleRecord = try CalendarEventRecord.fetch(key: CalendarEventKey(icalUid: "stale", recurrenceId: ""), in: db)
                #expect(healthyRecord?.title == "fresh")
                #expect(staleRecord?.title == "stale")
            }
            blocked.resume(state: .failed)
            await refresh.value
            #expect(collection.state == .failed)
            #expect(collection.hasLoadedConnection)
            #expect(collection.loadedEvents.map(\.title) == ["fresh"])
            collection.setEnabled(false, for: catalog[0].id)
            #expect(collection.state == .loaded)
        }

        @Test
        func removingAConnectionRejectsItsLateCompletionWithoutChangingTheOtherSelection() async {
            var catalog = [connection(google: true), connection()]
            let original = catalog
            let blocked = Store(events: [event("old")], state: .loading, blocksRefresh: true)
            let ready = Store(events: [event("keep")])
            let collection = CalendarProviderCollection(
                defaults: defaults(enabling: catalog), observesChanges: false, loadConnections: { catalog },
                makeStore: { $0.id == original[0].id ? blocked : ready }
            )
            await collection.reloadConnections()
            let refresh = Task { await collection.refreshIfNeeded(force: true) }
            await blocked.waitUntilStarted()
            catalog.removeFirst()
            await collection.reloadConnections()
            #expect(!blocked.active)
            blocked.replace([event("late")], state: .loaded)
            blocked.resume(state: .loaded)
            await refresh.value
            #expect(collection.connections == catalog)
            #expect(collection.enabledIDs == [catalog[0].id])
            #expect(collection.upcomingEvents.map(\.title) == ["keep"])
        }

        @Test
        func anEmptyCatalogDoesNotCreateAnUnauthenticatedGoogleRow() async {
            var creations = 0
            let collection = CalendarProviderCollection(
                defaults: defaults(enabling: []), observesChanges: false, loadConnections: { [] },
                makeStore: { _ in creations += 1
                    return Store()
                }
            )
            await collection.reloadConnections()
            await collection.refreshIfNeeded(force: true)
            #expect(collection.connections.isEmpty)
            #expect(collection.enabledIDs.isEmpty)
            #expect(creations == 0)
        }

        @Test
        func serviceIdentityAllowsAnotherCalendarAdapterOnTheSameDatabricksAccount() async {
            let google = connection()
            let microsoft = CalendarProviderConnection(provider: google.provider, service: .microsoft365, displayName: "Microsoft 365")
            #expect(google.id != microsoft.id)
            #expect(microsoft.googleRoute == nil)
            let collection = CalendarProviderCollection(
                defaults: defaults(enabling: [google, microsoft]), observesChanges: false,
                loadConnections: { [google, microsoft] }, makeStore: { Store(events: [event("same-transport-id", uid: $0.id)]) }
            )
            await collection.reloadConnections()
            await collection.refreshIfNeeded(force: true)
            #expect(collection.upcomingEvents.count == 2)
            #expect(Set(collection.upcomingEvents.map(\.displayID)).count == 2)
            #expect(Set(collection.upcomingEvents.compactMap(\.providerID)) == [google.id, microsoft.id])
            #expect(collection.isLoaded)
        }

        @Test
        func eventIdentityIsScopedAndOnlyPhysicalCopiesAcrossProvidersAreMerged() throws {
            let first = event("same-transport-id").scoped(to: "first")
            let second = event("same-transport-id").scoped(to: "second")
            #expect(first.displayID != second.displayID)
            #expect(first.key == second.key)
            #expect([first, second].deduplicatedAcrossSources().count == 1)
            #expect([first, first].deduplicatedAcrossSources().count == 2)
            let other = CalendarEvent(
                id: first.id, calendarID: "primary", calendarName: "Calendar", calendarColorHex: nil,
                platformId: first.platformId, title: "Different meeting", description: "", icalUid: "other-uid",
                startDate: first.startDate, endDate: first.endDate, isAllDay: false, conferenceURI: nil
            ).scoped(to: "second")
            #expect([first, other].deduplicatedAcrossSources().count == 2)
            let decoded = try JSONDecoder().decode(CalendarEvent.self, from: JSONEncoder().encode(first))
            #expect(decoded.providerID == "first")
            #expect(decoded.displayID == first.displayID)
        }

        @Test
        func missingICalendarUIDStillKeepsRecordingAndNotificationIdentitiesSeparate() throws {
            let raw = CalendarEvent(
                id: "primary::same-id", calendarID: "primary", calendarName: "Calendar", calendarColorHex: nil,
                platformId: "same-id", title: "Meeting", description: "", icalUid: nil,
                startDate: .distantPast, endDate: .distantFuture, isAllDay: false, conferenceURI: nil
            )
            let first = raw.scoped(to: "first")
            let second = raw.scoped(to: "second")
            let firstID = CalendarAutoRecordingEventID(event: first)
            let secondID = CalendarAutoRecordingEventID(event: second)
            #expect(firstID != secondID)
            #expect(firstID.sortKey != secondID.sortKey)
            #expect(MeetingNotificationService.calendarNotificationIdentifier(for: first) != MeetingNotificationService
                .calendarNotificationIdentifier(for: second))
            let decoded = try JSONDecoder().decode(CalendarAutoRecordingEventID.self, from: JSONEncoder().encode(firstID))
            #expect(decoded == firstID)
            let sharedFirst = event("shared").scoped(to: "first")
            let sharedSecond = event("shared").scoped(to: "second")
            #expect(CalendarAutoRecordingEventID(event: sharedFirst) == CalendarAutoRecordingEventID(event: sharedSecond))
            #expect(MeetingNotificationService.calendarNotificationIdentifier(for: sharedFirst) == MeetingNotificationService
                .calendarNotificationIdentifier(for: sharedSecond))
        }

        @Test
        func anotherAccountsDeclineDoesNotHideAnAcceptedCopyOfTheSameMeeting() {
            func copy(attending: Bool, declined: Bool, provider: String) -> CalendarEvent {
                CalendarEvent(
                    id: "shared", calendarID: "primary", calendarName: "Calendar", calendarColorHex: nil,
                    platformId: "shared", title: "Meeting", description: "", icalUid: "shared", startDate: .distantPast,
                    endDate: .distantFuture, isAllDay: false, isDeclined: declined, isAttending: attending, conferenceURI: nil
                ).scoped(to: provider)
            }
            let accepted = copy(attending: true, declined: false, provider: "work")
            let declined = copy(attending: false, declined: true, provider: "personal")
            for events in [[accepted, declined], [declined, accepted]] {
                let merged = events.deduplicatedAcrossSources()
                #expect(merged.count == 1)
                #expect(merged.first?.isAttending == true)
                #expect(merged.first?.isDeclined == false)
            }
        }

        private func connection(google: Bool = false) -> CalendarProviderConnection {
            CalendarProviderConnection(
                provider: google ? .google(connectionID: .v7()) : .databricks(connectionID: .v7()),
                service: .googleCalendar,
                displayName: "Provider"
            )
        }

        private func defaults(enabling connections: [CalendarProviderConnection]) -> UserDefaults {
            let defaults = UserDefaults(suiteName: "CalendarProviderCollectionTests.\(UUID())")!
            defaults.set(connections.map(\.id), forKey: CalendarProviderCollection.enabledConnectionsKey)
            return defaults
        }

        private func event(_ id: String, title: String? = nil, uid: String? = nil) -> CalendarEvent {
            CalendarEvent(
                id: id, calendarID: "primary", calendarName: "Calendar", calendarColorHex: nil, platformId: id,
                title: title ?? id, description: "", icalUid: uid ?? id, startDate: Date(timeIntervalSince1970: 1000),
                endDate: Date(timeIntervalSince1970: 2000), isAllDay: false, conferenceURI: nil
            )
        }
    }

    @MainActor
    private final class Store: CalendarConnectionStore {
        let source: CalendarSource = .google
        @Published var state: CalendarConnectionState
        @Published var upcomingEvents: [CalendarEvent]
        var lastErrorMessage: String? { state == .failed ? "Failed" : nil }
        var active = true
        var refreshCount = 0
        let blocksRefresh: Bool
        private var started: CheckedContinuation<Void, Never>?
        private var pending: CheckedContinuation<CalendarConnectionState, Never>?
        var isLoaded: Bool { state == .loaded }
        var upcomingEventsPublisher: AnyPublisher<[CalendarEvent], Never> { $upcomingEvents.eraseToAnyPublisher() }
        var statePublisher: AnyPublisher<Bool, Never> { $state.map { $0 == .loaded }.eraseToAnyPublisher() }
        var connectionStatePublisher: AnyPublisher<CalendarConnectionState, Never> { $state.eraseToAnyPublisher() }

        init(events: [CalendarEvent] = [], state: CalendarConnectionState = .loaded, blocksRefresh: Bool = false) {
            self.state = state
            self.upcomingEvents = events
            self.blocksRefresh = blocksRefresh
        }

        func setActive(_ active: Bool) { self.active = active }
        func refreshIfNeeded(force _: Bool) async {
            refreshCount += 1
            if blocksRefresh {
                state = await withCheckedContinuation { continuation in
                    pending = continuation
                    started?.resume()
                    started = nil
                }
            } else {
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if refreshCount > 0 { return }
            await withCheckedContinuation { started = $0 }
        }

        func resume(state: CalendarConnectionState) { pending?.resume(returning: state)
            pending = nil
        }

        func replace(_ events: [CalendarEvent], state: CalendarConnectionState) {
            upcomingEvents = events
            self.state = state
        }
    }
#endif
