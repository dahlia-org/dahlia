import AppKit
import Combine
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct GoogleCalendarStoreTests {
        @Test
        func unconfiguredStoreStartsInUnconfiguredState() {
            let store = GoogleCalendarStore(
                signInProvider: MockGoogleCalendarSignInProvider(isConfigured: false),
                apiClient: MockGoogleCalendarAPIClient(),
                userDefaults: isolatedUserDefaults(),
                openAccount: { .local }
            )

            #expect(store.state == .unconfigured)
            #expect(!store.isConfigured)
        }

        @Test
        func restorePreviousSessionLoadsCalendarsAndEvents() async {
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars(["primary"], defaults: defaults)

            let signInProvider = MockGoogleCalendarSignInProvider(
                hasPreviousSignIn: true,
                restoreResult: .success(fixtureSession)
            )
            let apiClient = MockGoogleCalendarAPIClient(
                calendars: [primaryCalendar],
                events: [fixtureEvent]
            )
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: apiClient,
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow }
            )

            await store.restoreSessionIfNeeded()

            #expect(store.state == .loaded)
            #expect(store.account == fixtureSession.account)
            #expect(store.availableCalendars == [primaryCalendar])
            #expect(store.upcomingEvents == [fixtureEvent])
            #expect(apiClient.fetchEventsCallCount == 1)
        }

        @Test
        func refreshTriggeredRestoreDoesNotCancelItsOwnerTask() async {
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars(["primary"], defaults: defaults)
            let apiClient = ControllableGoogleCalendarAPIClient(
                initialEvents: [fixtureEvent],
                suspendsCalendarList: true
            )
            let store = GoogleCalendarStore(
                signInProvider: MockGoogleCalendarSignInProvider(
                    hasPreviousSignIn: true,
                    restoreResult: .success(fixtureSession),
                    refreshResult: .success(fixtureSession)
                ),
                apiClient: apiClient,
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow }
            )

            let refresh = Task { await store.refreshIfNeeded() }
            await apiClient.waitUntilCalendarListFetchStarts()
            apiClient.finishCalendarListFetch()
            await refresh.value

            #expect(store.availableCalendars == [primaryCalendar])
            #expect(store.upcomingEvents == [fixtureEvent])
            #expect(store.state == .loaded)
        }

        @Test
        func olderRefreshCannotOverwriteANewerResult() async {
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars(["primary"], defaults: defaults)
            let signInProvider = MockGoogleCalendarSignInProvider(
                hasPreviousSignIn: true,
                restoreResult: .success(fixtureSession),
                refreshResult: .success(fixtureSession)
            )
            let apiClient = ControllableGoogleCalendarAPIClient(initialEvents: [fixtureEvent])
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: apiClient,
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow }
            )
            await store.restoreSessionIfNeeded()

            let olderRefresh = Task { await store.refreshIfNeeded(force: true) }
            await apiClient.waitForFetchEventsCallCount(2)
            let newerRefresh = Task { await store.refreshIfNeeded(force: true) }
            await apiClient.waitForFetchEventsCallCount(3)

            let newerEvent = calendarEvent(id: "newer")
            apiClient.resumePendingRequest(at: 1, with: [newerEvent])
            await newerRefresh.value
            apiClient.resumePendingRequest(at: 0, with: [calendarEvent(id: "older")])
            await olderRefresh.value

            #expect(store.upcomingEvents == [newerEvent])
            #expect(store.state == .loaded)
        }

        @Test
        func identicalBackgroundRefreshKeepsLoadedStateAndCoalescesRequests() async {
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars(["primary"], defaults: defaults)
            let apiClient = ControllableGoogleCalendarAPIClient(initialEvents: [fixtureEvent])
            let store = GoogleCalendarStore(
                signInProvider: MockGoogleCalendarSignInProvider(
                    hasPreviousSignIn: true,
                    restoreResult: .success(fixtureSession),
                    refreshResult: .success(fixtureSession)
                ),
                apiClient: apiClient,
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow },
                refreshInterval: 0
            )
            await store.restoreSessionIfNeeded()

            var eventPublicationCount = 0
            let cancellable = store.$upcomingEvents.dropFirst().sink { _ in eventPublicationCount += 1 }
            let firstRefresh = Task { await store.refreshIfNeeded() }
            await apiClient.waitForFetchEventsCallCount(2)
            let coalescedRefresh = Task { await store.refreshIfNeeded() }
            await Task.yield()

            #expect(store.state == .loaded)
            #expect(store.upcomingEvents == [fixtureEvent])
            #expect(apiClient.fetchEventsCallCount == 2)

            apiClient.resumePendingRequest(at: 0, with: [fixtureEvent])
            await firstRefresh.value
            await coalescedRefresh.value

            #expect(eventPublicationCount == 0)
            #expect(store.state == .loaded)
            withExtendedLifetime(cancellable) {}
        }

        @Test
        func cancellingOneCallerKeepsACoalescedRefreshAlive() async {
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars(["primary"], defaults: defaults)
            let apiClient = ControllableGoogleCalendarAPIClient(initialEvents: [fixtureEvent])
            let store = GoogleCalendarStore(
                signInProvider: MockGoogleCalendarSignInProvider(
                    hasPreviousSignIn: true,
                    restoreResult: .success(fixtureSession),
                    refreshResult: .success(fixtureSession)
                ),
                apiClient: apiClient,
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow },
                refreshInterval: 0
            )
            await store.restoreSessionIfNeeded()

            let firstCaller = Task { await store.refreshIfNeeded() }
            await apiClient.waitForFetchEventsCallCount(2)
            let remainingCaller = Task { await store.refreshIfNeeded() }
            firstCaller.cancel()

            let updatedEvent = calendarEvent(id: "updated")
            apiClient.resumePendingRequest(at: 0, with: [updatedEvent])
            await firstCaller.value
            await remainingCaller.value

            #expect(apiClient.fetchEventsCallCount == 2)
            #expect(store.upcomingEvents == [updatedEvent])
            #expect(store.state == .loaded)
        }

        @Test
        func initialRefreshCancellationDoesNotMarkTheStoreLoaded() async {
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars(["primary"], defaults: defaults)
            let store = GoogleCalendarStore(
                signInProvider: MockGoogleCalendarSignInProvider(
                    hasPreviousSignIn: true,
                    restoreResult: .success(fixtureSession),
                    refreshResult: .success(fixtureSession)
                ),
                apiClient: MockGoogleCalendarAPIClient(
                    calendars: [primaryCalendar],
                    eventsResult: .failure(CancellationError())
                ),
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow }
            )

            await store.restoreSessionIfNeeded()

            #expect(store.state == .loading)
            #expect(store.upcomingEvents.isEmpty)
        }

        @Test
        func revokedDatabricksGoogleCredentialOnRefreshSignsOutWithoutError() async {
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars(["primary"], defaults: defaults)
            let apiClient = ControllableGoogleCalendarAPIClient(initialEvents: [fixtureEvent])
            let store = GoogleCalendarStore(
                signInProvider: MockGoogleCalendarSignInProvider(hasPreviousSignIn: true),
                apiClient: apiClient,
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow }
            )
            await store.restoreSessionIfNeeded()

            let refresh = Task { await store.refreshIfNeeded(force: true) }
            await apiClient.waitForFetchEventsCallCount(2)
            apiClient.failPendingRequest(at: 0, with: GoogleCalendarAPIError.proxyError(
                errorCode: "UNAUTHENTICATED",
                message: "Credential for user identity('1') is not found for the connection 'system_ai_agent_google_calendar'."
            ))
            await refresh.value

            #expect(store.state == .signedOut)
            #expect(!store.isAuthorized)
            #expect(store.lastErrorMessage == nil)
            #expect(store.selectedCalendarIDs == ["primary"])
        }

        @Test
        func rejectedProxyGoogleCredentialClearsSessionAndPreservesSelectionUntilReconnect() async {
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars(["primary"], defaults: defaults)
            let apiClient = ControllableGoogleCalendarAPIClient(initialEvents: [fixtureEvent])
            let store = GoogleCalendarStore(
                signInProvider: MockGoogleCalendarSignInProvider(hasPreviousSignIn: true),
                apiClient: apiClient, userDefaults: defaults, openAccount: { .local }, now: { fixtureNow },
                presentingWindowProvider: { NSWindow() }
            )
            await store.restoreSessionIfNeeded()

            let refresh = Task { await store.refreshIfNeeded(force: true) }
            await apiClient.waitForFetchEventsCallCount(2)
            apiClient.failPendingRequest(at: 0, with: GoogleCalendarAPIError.proxyGoogleAuthenticationRequired)
            await refresh.value

            #expect(store.state == .failed)
            #expect(!store.isAuthorized)
            #expect(store.upcomingEvents.isEmpty)
            #expect(store.lastErrorMessage == L10n.googleDatabricksReauthenticationRequired)
            #expect(store.selectedCalendarIDs == ["primary"])

            let reconnect = Task { await store.signIn() }
            await apiClient.waitForFetchEventsCallCount(3)
            apiClient.resumePendingRequest(at: 0, with: [fixtureEvent])
            await reconnect.value
            #expect(store.isAuthorized)
            #expect(store.state == .loaded)
            #expect(store.lastErrorMessage == nil)
        }

        @Test
        func retryAfterCachedRefreshFailureShowsLoading() async {
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars(["primary"], defaults: defaults)
            let apiClient = ControllableGoogleCalendarAPIClient(initialEvents: [fixtureEvent])
            let store = GoogleCalendarStore(
                signInProvider: MockGoogleCalendarSignInProvider(
                    hasPreviousSignIn: true,
                    restoreResult: .success(fixtureSession),
                    refreshResult: .success(fixtureSession)
                ),
                apiClient: apiClient,
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow }
            )
            await store.restoreSessionIfNeeded()

            let failedRefresh = Task { await store.refreshIfNeeded(force: true) }
            await apiClient.waitForFetchEventsCallCount(2)
            apiClient.failPendingRequest(at: 0)
            await failedRefresh.value
            #expect(store.state == .failed)

            let retry = Task { await store.refreshIfNeeded(force: true) }
            await apiClient.waitForFetchEventsCallCount(3)
            #expect(store.state == .loading)
            apiClient.resumePendingRequest(at: 0, with: [fixtureEvent])
            await retry.value

            #expect(store.state == .loaded)
        }

        @Test
        func disconnectInvalidatesAnInFlightRefresh() async {
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars(["primary"], defaults: defaults)
            let signInProvider = MockGoogleCalendarSignInProvider(
                hasPreviousSignIn: true,
                restoreResult: .success(fixtureSession),
                refreshResult: .success(fixtureSession)
            )
            let apiClient = ControllableGoogleCalendarAPIClient(initialEvents: [fixtureEvent])
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: apiClient,
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow }
            )
            await store.restoreSessionIfNeeded()

            let refresh = Task { await store.refreshIfNeeded(force: true) }
            await apiClient.waitForFetchEventsCallCount(2)
            await store.disconnect()
            apiClient.resumePendingRequest(at: 0, with: [calendarEvent(id: "old-account")])
            await refresh.value

            #expect(store.upcomingEvents.isEmpty)
            #expect(store.state == .signedOut)
        }

        @Test
        func refreshIsIgnoredWhileDisconnectIsInProgress() async {
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars(["primary"], defaults: defaults)
            let signInProvider = MockGoogleCalendarSignInProvider(
                hasPreviousSignIn: true,
                restoreResult: .success(fixtureSession),
                refreshResult: .success(fixtureSession),
                suspendsDisconnect: true
            )
            let apiClient = MockGoogleCalendarAPIClient(
                calendars: [primaryCalendar],
                events: [fixtureEvent]
            )
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: apiClient,
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow }
            )
            await store.restoreSessionIfNeeded()

            let disconnect = Task { await store.disconnect() }
            await signInProvider.waitUntilDisconnectStarts()
            await store.refreshIfNeeded(force: true)

            #expect(apiClient.fetchEventsCallCount == 1)
            #expect(store.upcomingEvents.isEmpty)
            signInProvider.finishDisconnect()
            await disconnect.value
            #expect(store.state == .signedOut)
        }

        @Test
        func refreshIsIgnoredUntilRestoredAccountCalendarsAreLoaded() async {
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars(["primary"], defaults: defaults)
            let signInProvider = MockGoogleCalendarSignInProvider(
                hasPreviousSignIn: true,
                restoreResult: .success(fixtureSession),
                refreshResult: .success(fixtureSession)
            )
            let apiClient = ControllableGoogleCalendarAPIClient(
                initialEvents: [fixtureEvent],
                suspendsCalendarList: true
            )
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: apiClient,
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow }
            )

            let restore = Task { await store.restoreSessionIfNeeded() }
            await apiClient.waitUntilCalendarListFetchStarts()
            await store.refreshIfNeeded(force: true)
            #expect(apiClient.fetchEventsCallCount == 0)

            apiClient.finishCalendarListFetch()
            await restore.value
            #expect(store.availableCalendars == [primaryCalendar])
            #expect(store.upcomingEvents == [fixtureEvent])
            #expect(store.state == .loaded)
        }

        @Test
        func restoreFailureMapsWebClientIDErrorToActionableMessage() async {
            let signInProvider = MockGoogleCalendarSignInProvider(
                hasPreviousSignIn: true,
                restoreResult: .failure(
                    NSError(
                        domain: "GoogleSignIn",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "invalid_request: client_secret is missing."]
                    )
                )
            )
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: MockGoogleCalendarAPIClient(),
                userDefaults: isolatedUserDefaults(),
                openAccount: { .local }
            )

            await store.restoreSessionIfNeeded()

            #expect(store.state == .failed)
            #expect(store.lastErrorMessage == L10n.googleCalendarClientSecretMissingMessage)
            #expect(store.account == nil)
        }

        @Test
        func restoreWithoutSelectedCalendarsRequiresSelection() async {
            let signInProvider = MockGoogleCalendarSignInProvider(
                hasPreviousSignIn: true,
                restoreResult: .success(fixtureSession)
            )
            let apiClient = MockGoogleCalendarAPIClient(calendars: [primaryCalendar], events: [])
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: apiClient,
                userDefaults: isolatedUserDefaults(),
                openAccount: { .local },
                now: { fixtureNow }
            )

            await store.restoreSessionIfNeeded()

            #expect(store.state == .needsCalendarSelection)
            #expect(store.upcomingEvents.isEmpty)
        }

        @Test
        func disconnectClearsSelectionAndCachedData() async {
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars(["primary"], defaults: defaults)

            let signInProvider = MockGoogleCalendarSignInProvider(
                hasPreviousSignIn: true,
                restoreResult: .success(fixtureSession)
            )
            let apiClient = MockGoogleCalendarAPIClient(
                calendars: [primaryCalendar],
                events: [fixtureEvent]
            )
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: apiClient,
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow }
            )

            await store.restoreSessionIfNeeded()
            await store.disconnect()

            #expect(signInProvider.disconnectCallCount == 1)
            #expect(store.state == .signedOut)
            #expect(store.selectedCalendarIDs.isEmpty)
            #expect(store.account == nil)
            #expect(store.availableCalendars.isEmpty)
            #expect(store.upcomingEvents.isEmpty)
        }

        @Test
        func setCalendarSelectionPersistsIDs() async {
            let defaults = isolatedUserDefaults()
            let signInProvider = MockGoogleCalendarSignInProvider(
                hasPreviousSignIn: true,
                restoreResult: .success(fixtureSession),
                refreshResult: .success(fixtureSession)
            )
            let apiClient = MockGoogleCalendarAPIClient(
                calendars: [primaryCalendar, secondaryCalendar],
                events: [fixtureEvent]
            )
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: apiClient,
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow }
            )

            await store.restoreSessionIfNeeded()
            store.setCalendarSelection([secondaryCalendar.id])

            #expect(store.selectedCalendarIDs == [secondaryCalendar.id])

            let saved = defaults.string(forKey: GoogleCalendarStore.selectedCalendarIDsKey(for: .local))
            #expect(saved?.contains(secondaryCalendar.id) == true)
        }

        /// Switching accounts changes the route, and each account keeps its own calendar selection; one without its own
        /// starts from the selection saved before selections became per account.
        @Test
        func accountChangeLoadsTheNewAccountsSelectionAndRestoresItsRoute() async {
            let defaults = isolatedUserDefaults()
            let databricks = CodexRuntimeProvider.databricks(connectionID: UUID())
            seedSelectedCalendars([primaryCalendar.id], defaults: defaults)
            defaults.set("[\"\(secondaryCalendar.id)\"]", forKey: GoogleCalendarStore.selectedCalendarIDsKey(for: databricks))
            var account = CodexRuntimeProvider.local
            let signInProvider = MockGoogleCalendarSignInProvider(hasPreviousSignIn: true)
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: MockGoogleCalendarAPIClient(calendars: [primaryCalendar, secondaryCalendar], events: []),
                userDefaults: defaults,
                openAccount: { account }
            )
            #expect(store.selectedCalendarIDs == [primaryCalendar.id])

            account = databricks
            NotificationCenter.default.post(name: .calendarAccountDidChange, object: nil)

            #expect(store.selectedCalendarIDs == [secondaryCalendar.id])
            #expect(await pollUntil { signInProvider.restoreCallCount == 1 })
        }

        /// A restore still running for the previous account must not publish its identity or calendars under the new one,
        /// even when the switch arrives while that restore is suspended.
        @Test
        func accountChangeRejectsTheRestoreStillRunningForThePreviousAccount() async {
            var account = CodexRuntimeProvider.local
            let signInProvider = MockGoogleCalendarSignInProvider(hasPreviousSignIn: true, suspendsRestore: true)
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: MockGoogleCalendarAPIClient(calendars: [primaryCalendar], events: []),
                userDefaults: isolatedUserDefaults(),
                openAccount: { account },
                now: { fixtureNow }
            )
            let previousRestore = Task { await store.restoreSessionIfNeeded() }
            #expect(await pollUntil { signInProvider.restoreCallCount == 1 })

            account = .databricks(connectionID: UUID())
            NotificationCenter.default.post(name: .calendarAccountDidChange, object: nil)
            #expect(await pollUntil { signInProvider.restoreCallCount == 2 })
            signInProvider.finishRestore()
            await previousRestore.value

            #expect(store.account == nil)
            #expect(store.availableCalendars.isEmpty)

            signInProvider.finishRestore()
            #expect(await pollUntil { store.account == fixtureSession.account })
        }

        @Test
        func signInRequestsCalendarScopes() async {
            let signInProvider = MockGoogleCalendarSignInProvider(signInResult: .success(fixtureSession))
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: MockGoogleCalendarAPIClient(calendars: [primaryCalendar], events: []),
                userDefaults: isolatedUserDefaults(),
                openAccount: { .local },
                now: { fixtureNow },
                presentingWindowProvider: { NSWindow() }
            )

            await store.signIn()

            #expect(signInProvider.signInRequestedScopes == [GoogleOAuthScope.calendar])
        }

        @Test
        func ignoresUnrelatedSessionChangeNotification() async {
            let watchedNotification = Notification.Name("GoogleCalendarStoreTests.watched.\(UUID().uuidString)")
            let ignoredNotification = Notification.Name("GoogleCalendarStoreTests.ignored.\(UUID().uuidString)")
            let signInProvider = MockGoogleCalendarSignInProvider(
                hasPreviousSignIn: true,
                sessionDidChangeNotification: watchedNotification,
                restoreResult: .success(fixtureSession)
            )
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: MockGoogleCalendarAPIClient(calendars: [primaryCalendar], events: []),
                userDefaults: isolatedUserDefaults(),
                openAccount: { .local }
            )

            NotificationCenter.default.post(name: ignoredNotification, object: nil)
            await Task.yield()

            #expect(store.state == .signedOut)
            #expect(signInProvider.restoreCallCount == 0)
        }

        @Test
        func disconnectNotificationImmediatelySignsOut() async {
            let watchedNotification = Notification.Name("GoogleCalendarStoreTests.disconnect.\(UUID().uuidString)")
            let defaults = isolatedUserDefaults()
            seedSelectedCalendars([primaryCalendar.id], defaults: defaults)
            let signInProvider = MockGoogleCalendarSignInProvider(
                hasPreviousSignIn: true,
                sessionDidChangeNotification: watchedNotification,
                signInResult: .success(fixtureSession)
            )
            let store = GoogleCalendarStore(
                signInProvider: signInProvider,
                apiClient: MockGoogleCalendarAPIClient(calendars: [primaryCalendar], events: [fixtureEvent]),
                userDefaults: defaults,
                openAccount: { .local },
                now: { fixtureNow },
                presentingWindowProvider: { NSWindow() }
            )

            NotificationCenter.default.post(
                name: watchedNotification,
                object: GoogleAuthSessionChangeReason.disconnected
            )

            #expect(await pollUntil { store.selectedCalendarIDs.isEmpty })
            #expect(store.state == .signedOut)
            #expect(signInProvider.restoreCallCount == 0)
        }

        @Test
        func eventTransformationPrefersConferenceEntryPointAndFiltersFutureWindow() throws {
            let conferenceItem = GoogleCalendarAPIClient.EventItem(
                id: "event-1",
                summary: "Weekly sync",
                description: "Discuss launch plan",
                iCalUID: "event-1@google.com",
                htmlLink: nil,
                hangoutLink: nil,
                start: .init(date: nil, dateTime: "2026-04-17T01:00:00Z"),
                end: .init(date: nil, dateTime: "2026-04-17T02:00:00Z"),
                originalStartTime: nil,
                conferenceData: .init(entryPoints: [
                    .init(uri: "tel:+81-3-1234-5678"),
                    .init(uri: "https://meet.google.com/abc-defg-hij"),
                ]),
                eventType: nil
            )
            let transformedEvent = try GoogleCalendarAPIClient.makeEvent(
                from: conferenceItem,
                calendarItem: primaryCalendar,
                calendar: .current
            )
            let event = try #require(transformedEvent)

            #expect(event.conferenceURI?.absoluteString == "https://meet.google.com/abc-defg-hij")
            #expect(event.platformId == "event-1")
            #expect(event.description == "Discuss launch plan")
            #expect(event.icalUid == "event-1@google.com")
            #expect(event.recurrenceId.isEmpty)
            #expect(!event.isAllDay)

            let intervalEnd = try #require(Calendar.current.date(byAdding: .day, value: 7, to: fixtureNow))
            let filtered = try GoogleCalendarAPIClient.sortAndFilter(
                [
                    event,
                    CalendarEvent(
                        id: "late",
                        calendarID: primaryCalendar.id,
                        calendarName: primaryCalendar.title,
                        calendarColorHex: nil,
                        platformId: "late",
                        title: "Outside window",
                        description: "",
                        icalUid: nil,
                        startDate: #require(Calendar.current.date(byAdding: .day, value: 9, to: fixtureNow)),
                        endDate: #require(Calendar.current.date(byAdding: .day, value: 9, to: fixtureNow)),
                        isAllDay: true,
                        conferenceURI: nil
                    ),
                ],
                now: fixtureNow,
                intervalEnd: intervalEnd
            )

            #expect(filtered == [event])
        }

        @Test
        func allDayEventIsAvailableForDisplayFiltering() throws {
            let allDayItem = GoogleCalendarAPIClient.EventItem(
                id: "event-2",
                summary: nil,
                description: nil,
                iCalUID: nil,
                htmlLink: nil,
                hangoutLink: nil,
                start: .init(date: "2026-04-18", dateTime: nil),
                end: .init(date: "2026-04-19", dateTime: nil),
                originalStartTime: nil,
                conferenceData: nil,
                eventType: nil
            )

            let event = try GoogleCalendarAPIClient.makeEvent(
                from: allDayItem,
                calendarItem: secondaryCalendar,
                calendar: Calendar(identifier: .gregorian)
            )

            #expect(event?.isAllDay == true)
        }

        @Test
        func outOfOfficeEventIsAvailableForDisplayFiltering() throws {
            let outOfOfficeItem = GoogleCalendarAPIClient.EventItem(
                id: "event-3",
                summary: "Out of office",
                description: nil,
                iCalUID: nil,
                htmlLink: nil,
                hangoutLink: nil,
                start: .init(date: nil, dateTime: "2026-04-18T01:00:00Z"),
                end: .init(date: nil, dateTime: "2026-04-18T02:00:00Z"),
                originalStartTime: nil,
                conferenceData: nil,
                eventType: "outOfOffice"
            )

            let event = try GoogleCalendarAPIClient.makeEvent(
                from: outOfOfficeItem,
                calendarItem: secondaryCalendar,
                calendar: .current
            )

            #expect(event?.isOutOfOffice == true)
        }
    }

#endif

private let fixtureNow = Date(timeIntervalSince1970: 1_776_384_000)

private let fixtureSession = GoogleSession(
    account: GoogleCalendarAccount(
        id: "user-1",
        displayName: "Kazuki Matsuda",
        email: "kazuki@example.com"
    ),
    accessToken: "token-1",
    grantedScopes: GoogleOAuthScope.authorizationScopes(for: GoogleOAuthScope.calendar)
)

private let primaryCalendar = CalendarListItem(
    id: "primary",
    title: "Primary",
    colorHex: "#4285F4",
    isPrimary: true
)

private let secondaryCalendar = CalendarListItem(
    id: "team@example.com",
    title: "Team",
    colorHex: "#34A853",
    isPrimary: false
)

private let fixtureEvent = CalendarEvent(
    id: "primary::event-1",
    calendarID: "primary",
    calendarName: "Primary",
    calendarColorHex: "#4285F4",
    platformId: "event-1",
    title: "Design review",
    description: "Review draft",
    icalUid: "event-1@google.com",
    startDate: fixtureNow.addingTimeInterval(3600),
    endDate: fixtureNow.addingTimeInterval(7200),
    isAllDay: false,
    conferenceURI: URL(string: "https://meet.google.com/test-link")
)

private func calendarEvent(id: String) -> CalendarEvent {
    CalendarEvent(
        id: "primary::\(id)",
        calendarID: "primary",
        calendarName: "Primary",
        calendarColorHex: "#4285F4",
        platformId: id,
        title: id,
        description: "",
        icalUid: "\(id)@google.com",
        startDate: fixtureNow.addingTimeInterval(3600),
        endDate: fixtureNow.addingTimeInterval(7200),
        isAllDay: false,
        conferenceURI: nil
    )
}

@MainActor
private final class MockGoogleCalendarSignInProvider: GoogleSignInProviding {
    let isConfigured: Bool
    let hasPreviousSignIn: Bool
    let sessionDidChangeNotification: Notification.Name
    var restoreResult: Result<GoogleSession, Error>
    var signInResult: Result<GoogleSession, Error>
    var refreshResult: Result<GoogleSession?, Error>
    private let suspendsDisconnect: Bool
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    private let suspendsRestore: Bool
    private var restoreContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var restoreCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var signInRequestedScopes: [Set<String>] = []

    init(
        isConfigured: Bool = true,
        hasPreviousSignIn: Bool = false,
        // Unique per mock, so a live provider reacting to another suite's workspace switch cannot reach this store.
        sessionDidChangeNotification: Notification.Name = Notification.Name("MockGoogleCalendarSignInProvider.\(UUID().uuidString)"),
        restoreResult: Result<GoogleSession, Error> = .success(fixtureSession),
        signInResult: Result<GoogleSession, Error> = .success(fixtureSession),
        refreshResult: Result<GoogleSession?, Error> = .success(fixtureSession),
        suspendsDisconnect: Bool = false,
        suspendsRestore: Bool = false
    ) {
        self.isConfigured = isConfigured
        self.hasPreviousSignIn = hasPreviousSignIn
        self.sessionDidChangeNotification = sessionDidChangeNotification
        self.restoreResult = restoreResult
        self.signInResult = signInResult
        self.refreshResult = refreshResult
        self.suspendsDisconnect = suspendsDisconnect
        self.suspendsRestore = suspendsRestore
    }

    func restorePreviousSignIn() async throws -> GoogleSession {
        restoreCallCount += 1
        if suspendsRestore {
            await withCheckedContinuation { restoreContinuations.append($0) }
        }
        return try restoreResult.get()
    }

    /// Resumes the oldest suspended restore.
    func finishRestore() {
        guard !restoreContinuations.isEmpty else { return }
        restoreContinuations.removeFirst().resume()
    }

    func signIn(withPresentingWindow _: NSWindow, requestedScopes: Set<String>) async throws -> GoogleSession {
        signInRequestedScopes.append(requestedScopes)
        return try signInResult.get()
    }

    func refreshCurrentSession() async throws -> GoogleSession? {
        try refreshResult.get()
    }

    func disconnect() async throws {
        disconnectCallCount += 1
        if suspendsDisconnect {
            await withCheckedContinuation { continuation in
                disconnectContinuation = continuation
            }
        }
    }

    func waitUntilDisconnectStarts() async {
        while disconnectCallCount == 0 {
            await Task.yield()
        }
    }

    func finishDisconnect() {
        disconnectContinuation?.resume()
        disconnectContinuation = nil
    }
}

@MainActor
private final class MockGoogleCalendarAPIClient: GoogleCalendarAPIClientProviding {
    private let calendarsResult: Result<[CalendarListItem], Error>
    private let eventsResult: Result<[CalendarEvent], Error>
    private(set) var fetchEventsCallCount = 0

    init(
        calendars: [CalendarListItem] = [],
        events: [CalendarEvent] = [],
        eventsResult: Result<[CalendarEvent], Error>? = nil
    ) {
        calendarsResult = .success(calendars)
        self.eventsResult = eventsResult ?? .success(events)
    }

    func fetchCalendarList(session _: GoogleSession) async throws -> [CalendarListItem] {
        try calendarsResult.get()
    }

    func fetchUpcomingEvents(
        session _: GoogleSession,
        calendars _: [CalendarListItem],
        now _: Date,
        daysAhead _: Int
    ) async throws -> [CalendarEvent] {
        fetchEventsCallCount += 1
        return try eventsResult.get()
    }
}

@MainActor
private final class ControllableGoogleCalendarAPIClient: GoogleCalendarAPIClientProviding {
    private let initialEvents: [CalendarEvent]
    private let suspendsCalendarList: Bool
    private var calendarListContinuation: CheckedContinuation<Void, Never>?
    private var pendingRequests: [CheckedContinuation<[CalendarEvent], any Error>] = []
    private(set) var fetchEventsCallCount = 0

    init(initialEvents: [CalendarEvent], suspendsCalendarList: Bool = false) {
        self.initialEvents = initialEvents
        self.suspendsCalendarList = suspendsCalendarList
    }

    func fetchCalendarList(session _: GoogleSession) async throws -> [CalendarListItem] {
        if suspendsCalendarList {
            await withCheckedContinuation { continuation in
                calendarListContinuation = continuation
            }
            try Task.checkCancellation()
        }
        return [primaryCalendar]
    }

    func fetchUpcomingEvents(
        session _: GoogleSession,
        calendars _: [CalendarListItem],
        now _: Date,
        daysAhead _: Int
    ) async throws -> [CalendarEvent] {
        fetchEventsCallCount += 1
        if fetchEventsCallCount == 1 {
            return initialEvents
        }
        let events = try await withCheckedThrowingContinuation { continuation in
            pendingRequests.append(continuation)
        }
        try Task.checkCancellation()
        return events
    }

    func waitForFetchEventsCallCount(_ expectedCount: Int) async {
        while fetchEventsCallCount < expectedCount {
            await Task.yield()
        }
    }

    func waitUntilCalendarListFetchStarts() async {
        while calendarListContinuation == nil {
            await Task.yield()
        }
    }

    func finishCalendarListFetch() {
        calendarListContinuation?.resume()
        calendarListContinuation = nil
    }

    func resumePendingRequest(at index: Int, with events: [CalendarEvent]) {
        pendingRequests.remove(at: index).resume(returning: events)
    }

    func failPendingRequest(at index: Int, with error: any Error = CalendarRefreshTestError.requestFailed) {
        pendingRequests.remove(at: index).resume(throwing: error)
    }
}

private func isolatedUserDefaults() -> UserDefaults {
    let suiteName = "GoogleCalendarStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@MainActor
private func seedSelectedCalendars(_ ids: [String], defaults: UserDefaults) {
    guard let data = try? JSONEncoder().encode(ids) else {
        preconditionFailure("Static calendar identifiers must be JSON encodable")
    }
    defaults.set(String(data: data, encoding: .utf8), forKey: GoogleCalendarStore.selectedCalendarIDsKey)
}
