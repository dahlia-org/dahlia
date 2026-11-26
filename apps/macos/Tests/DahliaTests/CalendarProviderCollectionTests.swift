import Combine
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CalendarProviderCollectionTests {
        @Test(arguments: [false, true])
        func firstLaunchHydratesExistingStoresAfterAccountMigration(explicitlyDisabled: Bool) async throws {
            let original = connection()
            let defaults = defaults(enabling: [])
            defaults.removeObject(forKey: CalendarProviderCollection.enabledConnectionsKey)
            let legacy = CalendarEvent(
                id: "legacy", calendarID: "primary", calendarName: "Calendar", calendarColorHex: nil,
                platformId: "legacy", title: "Meeting", description: "", icalUid: nil,
                startDate: .distantPast, endDate: .distantFuture, isAllDay: false, conferenceURI: nil
            )
            try defaults.set(
                JSONEncoder().encode([CalendarAutoRecordingSelection(event: legacy)]),
                forKey: CalendarAutoRecordingStore.selectionsUserDefaultsKey
            )
            let reservations = CalendarAutoRecordingStore(userDefaults: defaults)
            let center = NotificationCenter()
            var catalogLoads = 0
            let collection = CalendarProviderCollection(
                defaults: defaults, notificationCenter: center, loadConnections: {
                    catalogLoads += 1
                    return [original]
                }, makeStore: { _ in Store(events: [legacy]) }
            )
            await Task.detached { center.post(name: .databricksConnectionDidChange, object: nil) }.value
            await collection.reloadConnections()
            await collection.refreshIfNeeded(force: true)
            #expect(catalogLoads == 0)
            #expect(defaults.object(forKey: CalendarProviderCollection.enabledConnectionsKey) == nil)
            // Account migration publishes the original owner and copies its settings after the shared stores exist.
            defaults.set(original.provider.connectionID.uuidString, forKey: SingleAccountMigration.sourceKey)
            defaults.set("[\"google\"]", forKey: CalendarSource.accountEnabledSourcesUserDefaultsKey)
            if explicitlyDisabled { defaults.set([], forKey: CalendarProviderCollection.enabledConnectionsKey) }
            reservations.activateAfterAccountMigration()
            await collection.activateAfterAccountMigration()
            #expect(collection.enabledIDs == (explicitlyDisabled ? [] : [original.id]))
            #expect(reservations.isEnabled(for: legacy.scoped(to: original.id)))
            let due = CalendarAutoRecordingPlanner.dueEvents(
                events: collection.loadedEvents, selections: reservations.selections, now: .now
            )
            #expect(due.count == (explicitlyDisabled ? 0 : 1))
            collection.setEnabled(false, for: original.id)
            reservations.setEnabled(false, for: legacy.scoped(to: original.id))
            reservations.activateAfterAccountMigration()
            await collection.activateAfterAccountMigration()
            #expect(collection.enabledIDs.isEmpty)
            #expect(reservations.selections.isEmpty)
        }

        @Test(arguments: [false, true])
        func releasedDatabricksEnablementUsesTheOriginalAccountRatherThanTheDriveChoice(explicitlyDisabled: Bool) async {
            let original = connection()
            let drive = connection()
            let defaults = defaults(enabling: [])
            defaults.removeObject(forKey: CalendarProviderCollection.enabledConnectionsKey)
            defaults.set(original.provider.connectionID.uuidString, forKey: SingleAccountMigration.sourceKey)
            defaults.set("[\"google\"]", forKey: CalendarSource.accountEnabledSourcesUserDefaultsKey)
            if explicitlyDisabled { defaults.set([], forKey: CalendarProviderCollection.enabledConnectionsKey) }
            let collection = CalendarProviderCollection(
                defaults: defaults, observesChanges: false, loadConnections: { [original, drive] }, makeStore: { _ in Store() }
            )
            await collection.activateAfterAccountMigration()
            #expect(collection.enabledIDs == (explicitlyDisabled ? [] : [original.id]))
            GoogleCalendarProvider.save(.databricks(connectionID: drive.provider.connectionID), defaults: defaults)
            let reopened = CalendarProviderCollection(
                defaults: defaults, observesChanges: false, loadConnections: { [original, drive] }, makeStore: { _ in Store() }
            )
            await reopened.activateAfterAccountMigration()
            #expect(reopened.enabledIDs == collection.enabledIDs)
        }

        @Test func calendarSignalsWaitForAnActualEventFetch() async {
            let provider = connection()
            let store = Store()
            store.hasFetchedEvents = false
            let collection = CalendarProviderCollection(
                defaults: defaults(enabling: [provider]),
                observesChanges: false,
                loadConnections: { [provider] },
                makeStore: { _ in store }
            )
            await collection.activateAfterAccountMigration()
            #expect(collection.successfullyLoadedProviderIDs.isEmpty)
            #expect(AgentCalendarSnapshot.current(enabledSources: [.google], providers: collection).selectedProviders == [provider.id])
            store.hasFetchedEvents = true
            #expect(collection.successfullyLoadedProviderIDs == [provider.id])
            store.state = .failed
            #expect(collection.successfullyLoadedProviderIDs.isEmpty)
            let failed = AgentCalendarSnapshot.current(enabledSources: [.google], providers: collection)
            #expect(failed.selectedProviders == [provider.id] && failed.successfulProviders.isEmpty)
            #expect(AgentCalendarSnapshot.current(enabledSources: [], providers: collection).selectedProviders?.isEmpty == true)
            collection.setEnabled(false, for: provider.id)
            #expect(AgentCalendarSnapshot.current(enabledSources: [.google], providers: collection).selectedProviders?.isEmpty == true)
        }

        @Test
        func displayMergesProviderRostersWhileLinkedMeetingsKeepOneLiveCopy() async throws {
            let catalog = [connection(), connection()]
            let first = event("first", uid: "shared", participants: [participant("one"), participant("two")])
            let second = event("second", uid: "shared", participants: [participant("three")])
            let stores = [catalog[0].id: Store(events: [first]), catalog[1].id: Store(events: [second])]
            let collection = CalendarProviderCollection(
                defaults: defaults(enabling: catalog), observesChanges: false,
                loadConnections: { catalog }, makeStore: { stores[$0.id]! }
            )
            await collection.activateAfterAccountMigration()
            let database = try AppDatabaseManager(path: ":memory:")
            try await database.dbQueue.write { db in
                let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Local", createdAt: .now, lastOpenedAt: .now)
                try workspace.insert(db)
                try CalendarEventRecord.upsert(event: first, now: .now, in: db)
                try MeetingRecord(
                    id: .v7(), workspaceId: workspace.id, name: "Meeting", createdAt: .now, updatedAt: .now,
                    calendarEventIcalUid: "shared", calendarEventRecurrenceId: ""
                ).insert(db)
            }
            let coordinator = CalendarSourceCoordinator(stores: [collection], dbQueue: database.dbQueue)
            await coordinator.refreshEnabledSources([.google])
            await coordinator.waitForPersistence()
            #expect(collection.upcomingEvents.first?.participants.count == 3)
            #expect(collection.loadedEvents.count == 2)
            try await database.dbQueue.read { db in
                let record = try #require(try CalendarEventRecord.fetch(key: .init(icalUid: "shared", recurrenceId: ""), in: db))
                #expect(record.attendees == first.participants.attendeeSnapshots)
            }
            collection.setEnabled(false, for: catalog[0].id)
            await coordinator.waitForPersistence()
            try await database.dbQueue.read { db in
                let record = try #require(try CalendarEventRecord.fetch(key: .init(icalUid: "shared", recurrenceId: ""), in: db))
                #expect(record.attendees == second.participants.attendeeSnapshots)
            }
        }

        @Test(arguments: [Notification.Name.databricksConnectionDidChange, GoogleCalendarProvider.didChange])
        func backgroundRegistrationAndSignOutNotificationsReloadTheCatalog(name: Notification.Name) async {
            let center = NotificationCenter()
            let registered = connection()
            var loadCount = 0
            let collection = CalendarProviderCollection(
                defaults: defaults(enabling: [registered]), notificationCenter: center,
                loadConnections: {
                    MainActor.assertIsolated()
                    loadCount += 1
                    return loadCount <= 2 ? [registered] : []
                }, makeStore: { _ in Store() }
            )
            await collection.activateAfterAccountMigration()
            await Task.detached { center.post(name: name, object: nil) }.value
            _ = await pollUntil { loadCount == 2 && collection.connections == [registered] }
            #expect(collection.connections == [registered])
            #expect(collection.enabledIDs == [registered.id])
            await Task.detached { center.post(name: name, object: nil) }.value
            _ = await pollUntil { collection.connections.isEmpty }
            #expect(collection.connections.isEmpty)
            #expect(collection.stores.isEmpty)
            #expect(collection.enabledIDs.isEmpty)
        }

        @Test
        func multipleGoogleAndDatabricksConnectionsHaveIndependentSwitchesAndSurviveReload() async {
            let catalog = [connection(google: true), connection(google: true), connection(), connection()]
            let defaults = defaults(enabling: catalog)
            let stores = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, Store(events: [event($0.id).scoped(to: $0.id)])) })
            let collection = CalendarProviderCollection(
                defaults: defaults, observesChanges: false, loadConnections: { catalog }, makeStore: { stores[$0.id]! }
            )
            await collection.activateAfterAccountMigration()
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
            await collection.activateAfterAccountMigration()
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
            await collection.activateAfterAccountMigration()
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
            await collection.activateAfterAccountMigration()
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
            await collection.activateAfterAccountMigration()
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
            await collection.activateAfterAccountMigration()
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

        private func participant(_ name: String) -> CalendarParticipant {
            CalendarParticipant(email: "\(name)@example.com", displayName: name, kind: .person, isCurrentUser: false)
        }

        private func event(_ id: String, title: String? = nil, uid: String? = nil, participants: [CalendarParticipant] = []) -> CalendarEvent {
            CalendarEvent(
                id: id, calendarID: "primary", calendarName: "Calendar", calendarColorHex: nil, platformId: id,
                title: title ?? id, description: "", icalUid: uid ?? id, startDate: Date(timeIntervalSince1970: 1000),
                endDate: Date(timeIntervalSince1970: 2000), isAllDay: false, participants: participants, conferenceURI: nil
            )
        }
    }

    @MainActor
    private final class Store: CalendarConnectionStore {
        let source: CalendarSource = .google
        @Published var state: CalendarConnectionState
        @Published var upcomingEvents: [CalendarEvent]
        var lastErrorMessage: String? { state == .failed ? "Failed" : nil }
        var hasFetchedEvents = true
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
