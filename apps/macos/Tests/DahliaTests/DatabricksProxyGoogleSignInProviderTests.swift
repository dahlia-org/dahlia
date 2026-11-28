import AppKit
import Combine
import Foundation
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    /// The Databricks connection the app's account uses for Google Calendar in these tests.
    private let proxyConnectionID = UUID()

    @MainActor
    @Suite(.providerAccounts([.init(id: proxyConnectionID, workspaceURL: URL(string: "https://example.cloud.databricks.com")!)]))
    struct DatabricksProxyGoogleSignInProviderTests {
        private let connection = DatabricksConnection(id: proxyConnectionID, host: "https://example.cloud.databricks.com")

        @Test(arguments: [false, true])
        func directConnectionsReuseGrantedScopesIncludingAfterDisconnect(hasAccess: Bool) async throws {
            let direct = FakeDirectProvider(hasPreviousSignIn: true)
            direct.session = GoogleSession(
                account: direct.session.account, accessToken: "shared-token",
                grantedScopes: hasAccess ? GoogleOAuthScope.calendar.union(GoogleOAuthScope.drive) : GoogleOAuthScope.base
            )
            let provider = DatabricksProxyGoogleSignInProvider(
                provider: .google(accountID: .v7()), direct: direct,
                storage: DatabricksTestStorage(connection: nil).storage,
                apiClient: FakeAPIClient(result: .success([])),
                userDefaults: makeDefaults()
            )
            _ = NSApplication.shared
            let window = NSWindow()
            let session = try await provider.signIn(withPresentingWindow: window, requestedScopes: GoogleOAuthScope.calendar)
            #expect(session == direct.session)
            #expect(direct.restoreCallCount == 1)
            #expect(direct.signInCallCount == (hasAccess ? 0 : 1))
            #expect(direct.requestedScopes == (hasAccess ? nil : GoogleOAuthScope.calendar))

            try await provider.disconnect()
            #expect(await provider.hasPreviousSignIn == false)
            #expect(direct.disconnectCallCount == 0)
            _ = try await provider.signIn(withPresentingWindow: window, requestedScopes: GoogleOAuthScope.calendar)
            #expect(await provider.hasPreviousSignIn)
            #expect(direct.restoreCallCount == 2)
            #expect(direct.signInCallCount == (hasAccess ? 0 : 2))
        }

        @Test
        func directConnectionWithoutSavedCredentialsRequestsAuthentication() async throws {
            let direct = FakeDirectProvider()
            let provider = makeProvider(connection: nil, direct: direct)
            _ = NSApplication.shared
            _ = try await provider.signIn(withPresentingWindow: NSWindow(), requestedScopes: GoogleOAuthScope.calendar)
            #expect(direct.restoreCallCount == 0)
            #expect(direct.signInCallCount == 1)
            #expect(direct.requestedScopes == GoogleOAuthScope.calendar)
        }

        @Test
        func directRestoreFailureSurfacesWithoutStartingAuthentication() async throws {
            _ = NSApplication.shared
            for error in [GoogleSignInError.invalidTokenResponse, URLError(.notConnectedToInternet), CancellationError()] as [any Error] {
                let direct = FakeDirectProvider(hasPreviousSignIn: true)
                direct.restoreError = error
                let provider = makeProvider(connection: nil, direct: direct)
                do {
                    _ = try await provider.signIn(withPresentingWindow: NSWindow(), requestedScopes: GoogleOAuthScope.calendar)
                    Issue.record("Expected the saved session failure")
                } catch {}
                #expect(direct.restoreCallCount == 1)
                #expect(direct.signInCallCount == 0)
            }
        }

        @Test
        func directConnectionCanReauthenticateAnUnusableSavedCredential() async throws {
            let direct = FakeDirectProvider(hasPreviousSignIn: true)
            direct.restoreError = GoogleSignInError.reauthenticationRequired
            let provider = DatabricksProxyGoogleSignInProvider(
                provider: .google(accountID: .v7()), direct: direct,
                storage: DatabricksTestStorage(connection: nil).storage, userDefaults: makeDefaults()
            )
            _ = NSApplication.shared
            try await provider.disconnect()
            _ = try await provider.signIn(withPresentingWindow: NSWindow(), requestedScopes: GoogleOAuthScope.calendar)
            #expect(direct.restoreCallCount == 1)
            #expect(direct.signInCallCount == 1)
            #expect(direct.requestedScopes == GoogleOAuthScope.calendar)
            #expect(await provider.hasPreviousSignIn)
        }

        @Test(arguments: [401, 403, 429, 500])
        func explicitConnectReauthenticatesOnlyWhenGoogleRejectsTheSavedToken(statusCode: Int) async throws {
            let direct = FakeDirectProvider(hasPreviousSignIn: true)
            direct.session = GoogleSession(
                account: direct.session.account, accessToken: String(statusCode),
                grantedScopes: GoogleOAuthScope.calendar.union(GoogleOAuthScope.drive)
            )
            let provider = DatabricksProxyGoogleSignInProvider(
                provider: .google(accountID: .v7()), direct: direct,
                storage: DatabricksTestStorage(connection: nil).storage,
                apiClient: FakeAPIClient(result: .failure(GoogleCalendarAPIError.httpError(statusCode: statusCode, detail: "test"))),
                userDefaults: makeDefaults()
            )
            _ = NSApplication.shared
            try await provider.disconnect()
            do {
                _ = try await provider.signIn(withPresentingWindow: NSWindow(), requestedScopes: GoogleOAuthScope.calendar)
                #expect(statusCode == 401)
            } catch {
                #expect(statusCode != 401)
            }
            #expect(direct.restoreCallCount == 1)
            #expect(direct.signInCallCount == (statusCode == 401 ? 1 : 0))
            #expect(await provider.hasPreviousSignIn == (statusCode == 401))
        }

        @Test
        func fixedCalendarRoutesIgnoreTheSavedChoiceAndDisconnectOnlyThemselves() async throws {
            let other = DatabricksConnection(id: .v7(), host: "https://other.cloud.databricks.com")
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.connections.append(other) }
            let defaults = makeDefaults()
            let oauth = DatabricksOAuthService(storage: memory.storage)
            let first = DatabricksProxyGoogleSignInProvider(
                provider: .databricks(connectionID: connection.id), oauth: oauth, storage: memory.storage, userDefaults: defaults
            )
            let second = DatabricksProxyGoogleSignInProvider(
                provider: .databricks(connectionID: other.id), oauth: oauth, storage: memory.storage, userDefaults: defaults
            )
            defaults.set("unassigned", forKey: GoogleCalendarProvider.userDefaultsKey)
            #expect(first.connectionPageURL?.host == "example.cloud.databricks.com")
            #expect(second.connectionPageURL?.host == "other.cloud.databricks.com")
            #expect(await first.hasPreviousSignIn)
            #expect(await second.hasPreviousSignIn)
            try await first.disconnect()
            #expect(await !(first.hasPreviousSignIn))
            #expect(await second.hasPreviousSignIn)
            #expect(GoogleCalendarProvider.current(defaults: defaults) == .unassigned)
        }

        enum ConnectInvalidation: CaseIterable, Sendable {
            case switchProvider, switchAwayAndBack, cancelCaller
        }

        @Test(arguments: ConnectInvalidation.allCases)
        func invalidatingASuspendedWorkspaceRefreshPreventsInteractiveFallback(invalidation: ConnectInvalidation) async throws {
            let host = "refresh-\(UUID().uuidString.lowercased()).example"
            let connection = DatabricksConnection(id: self.connection.id, host: "https://\(host)")
            let memory = DatabricksTestStorage(connection: connection)
            let credential = try DatabricksOAuthCredential(
                accessToken: "expired", refreshToken: "refresh", expirationDate: .distantPast,
                tokenEndpoint: #require(URL(string: "https://\(host)/oidc/v1/token"))
            )
            memory.state.withLock { $0.credentials[connection.id] = credential }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SuspendedWorkspaceTokenURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let authorizations = Mutex(0)
            let oauth = DatabricksOAuthService(session: transport, storage: memory.storage) { _ in
                authorizations.withLock { $0 += 1 }
                throw CancellationError()
            }
            let defaults = makeDefaults()
            let route = GoogleCalendarProvider.databricks(connectionID: connection.id)
            GoogleCalendarProvider.save(route, defaults: defaults)
            let provider = DatabricksProxyGoogleSignInProvider(oauth: oauth, storage: memory.storage, userDefaults: defaults)
            try await provider.disconnect()
            _ = NSApplication.shared
            let window = NSWindow()
            let connect = Task {
                await #expect(throws: CancellationError.self) {
                    try await provider.signIn(withPresentingWindow: window, requestedScopes: GoogleOAuthScope.calendar)
                }
            }
            defer { connect.cancel() }
            #expect(await pollUntil { SuspendedWorkspaceTokenURLProtocol.pending.withLock { $0[host] != nil } })
            let failRefresh = try #require(SuspendedWorkspaceTokenURLProtocol.pending.withLock { $0.removeValue(forKey: host) })
            switch invalidation {
            case .switchProvider, .switchAwayAndBack:
                GoogleCalendarProvider.save(.unassigned, defaults: defaults)
                if invalidation == .switchAwayAndBack { GoogleCalendarProvider.save(route, defaults: defaults) }
            case .cancelCaller:
                connect.cancel()
            }
            failRefresh()
            _ = await connect.value
            #expect(authorizations.withLock { $0 } == 0)
            #expect(defaults.bool(forKey: DatabricksProxyGoogleSignInProvider.disconnectedKey(for: connection)))
            #expect(memory.state.withLock { $0.credentials[connection.id]?.accessToken } == "expired")
        }

        @Test
        func proxyBaseURLUsesAPI20Route() {
            #expect(
                DatabricksProxyGoogleSignInProvider.proxyBaseURL(for: connection).absoluteString
                    == "https://example.cloud.databricks.com/api/2.0/unity-catalog/connections/system_ai_agent_google_calendar/proxy/"
            )
            #expect(
                DatabricksProxyGoogleSignInProvider.signInPageURL(for: connection).absoluteString
                    == "https://example.cloud.databricks.com/explore/connections/system_ai_agent_google_calendar"
            )
        }

        @Test
        func onlyUCMissingCredentialMeansNoGoogleAuthorization() {
            #expect(DatabricksProxyGoogleSignInProvider.isNotAuthorized(Self.noGrant))
            // Observed on 2026-11-05: a bad Databricks token on a workspace host and on a vanity alias, and an alias that
            // cannot load the connection's OAuth config. A forwarded Google rate limit must surface too.
            for error in [
                Self.databricksError(403, "403", "Invalid access token. [ReqId: x]"),
                Self.databricksError(401, "401", "Credential was not sent or was of an unsupported type for this API."),
                GoogleCalendarAPIError.httpError(statusCode: 400, detail: "Unable to load OAuth Config"),
                Self.googleRateLimit,
                GoogleCalendarAPIError.proxyError(errorCode: "PERMISSION_DENIED", message: "No USE CONNECTION"),
                .invalidResponse,
            ] {
                #expect(!DatabricksProxyGoogleSignInProvider.isNotAuthorized(error))
            }
        }

        @Test
        func withoutDatabricksConnectionEverythingGoesToDirectProvider() async throws {
            let direct = FakeDirectProvider(isConfigured: false, hasPreviousSignIn: true)
            let provider = makeProvider(connection: nil, direct: direct)

            #expect(provider.isConfigured == false)
            #expect(provider.isProxyActive == false)
            #expect(provider.restoresThroughProxy == false)
            #expect(await provider.hasPreviousSignIn == true)
            _ = try await provider.restorePreviousSignIn()
            try await provider.disconnect()
            #expect(direct.restoreCallCount == 1)
            #expect(direct.disconnectCallCount == 1)
        }

        /// Google Calendar comes from the provider the user chose: Google itself, or the Databricks connection.
        @Test
        func anUnsetChoiceUsesDirectGoogleEvenWhenDatabricksIsAvailable() async throws {
            let defaults = makeDefaults()
            defaults.removeObject(forKey: GoogleCalendarProvider.userDefaultsKey)
            let direct = FakeDirectProvider(isConfigured: true, hasPreviousSignIn: true)
            let provider = makeProvider(connection: connection, direct: direct, userDefaults: defaults)
            #expect(!provider.isProxyActive)
            _ = try await provider.restorePreviousSignIn()
            #expect(direct.restoreCallCount == 1)
        }

        @Test
        func disconnectingTheProxyDoesNotPublishADirectGoogleSignOut() async throws {
            let direct = FakeDirectProvider()
            let provider = makeProvider(connection: connection, direct: direct)
            let directChanges = Mutex(0)
            let observer = NotificationCenter.default.addObserver(forName: direct.sessionDidChangeNotification, object: nil, queue: .main) { _ in
                directChanges.withLock { $0 += 1 }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            try await provider.disconnect()
            #expect(directChanges.withLock { $0 } == 0)
            #expect(direct.disconnectCallCount == 0)
        }

        @Test
        func calendarFollowsTheChosenProvider() async throws {
            let defaults = makeDefaults()
            let direct = FakeDirectProvider(isConfigured: true, hasPreviousSignIn: true)
            let calendar = makeProvider(connection: connection, direct: direct, userDefaults: defaults)
            #expect(calendar.isProxyActive)

            defaults.set("google", forKey: GoogleCalendarProvider.userDefaultsKey)
            #expect(calendar.isProxyActive == false)
            _ = try await calendar.restorePreviousSignIn()
            #expect(direct.restoreCallCount == 1)

            defaults.set(connection.id.uuidString, forKey: GoogleCalendarProvider.userDefaultsKey)
            #expect(calendar.isProxyActive)
        }

        @Test
        func theChoiceNeverAutomaticallySelectsADatabricksConnection() throws {
            let defaults = makeDefaults()
            defaults.removeObject(forKey: GoogleCalendarProvider.userDefaultsKey)
            let id = UUID.v7()
            try ProviderAccountDirectory.$connections.withValue([.init(
                id: id,
                workspaceURL: #require(URL(string: "https://dbc-1.cloud.databricks.com"))
            )]) {
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .unassigned)
                defaults.set("google", forKey: GoogleCalendarProvider.userDefaultsKey)
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .unassigned)
                defaults.set(UUID.v7().uuidString, forKey: GoogleCalendarProvider.userDefaultsKey)
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .unassigned)
            }
            ProviderAccountDirectory.$connections.withValue([]) {
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .unassigned)
            }
        }

        @Test
        func databricksConnectionRestoresWhateverTheProxyGrants() async throws {
            let direct = FakeDirectProvider(isConfigured: false, hasPreviousSignIn: false)
            let apiClient = FakeAPIClient(result: .success([Self.primaryCalendar]))
            let provider = makeProvider(connection: connection, direct: direct, apiClient: apiClient)

            #expect(provider.isConfigured)
            #expect(await provider.hasPreviousSignIn)
            #expect(try await provider.restorePreviousSignIn().account.id == "me@example.com")
            #expect(direct.restoreCallCount == 0)
        }

        @Test
        func restoreWithoutGoogleGrantStaysSignedOutWithoutError() async throws {
            let provider = makeProvider(
                connection: connection,
                direct: FakeDirectProvider(),
                apiClient: FakeAPIClient(result: .failure(Self.noGrant))
            )

            let error = await #expect(throws: GoogleSignInError.self) { try await provider.restorePreviousSignIn() }
            #expect(error?.errorDescription == L10n.googleAccountNoPreviousSession)
        }

        @Test
        func restoreLeavesAnUnusableRouteSignedOut() async throws {
            for error in [
                Self.databricksError(404, "RESOURCE_DOES_NOT_EXIST", "Connection 'system_ai_agent_google_calendar' does not exist."),
                Self.databricksError(403, "PERMISSION_DENIED", "User does not have USE CONNECTION"),
                Self.databricksError(401, "401", "Credential was not sent or was of an unsupported type for this API."),
                GoogleCalendarAPIError.httpError(statusCode: 400, detail: "Unable to load OAuth Config"),
            ] {
                let provider = makeProvider(connection: connection, direct: FakeDirectProvider(), apiClient: FakeAPIClient(result: .failure(error)))

                let thrown = await #expect(throws: GoogleSignInError.self) { try await provider.restorePreviousSignIn() }
                #expect(thrown?.errorDescription == L10n.googleAccountNoPreviousSession)
            }
            #expect(DatabricksProxyGoogleSignInProvider.isUnusableRoute(DahliaCloudError.tokenRequestFailed(400)))
            #expect(!DatabricksProxyGoogleSignInProvider.isUnusableRoute(DahliaCloudError.tokenRequestFailed(503)))
        }

        @Test
        func rejectedGoogleCredentialSurfacesRecoveryOnRestoreAndConnect() async throws {
            let apiClient = FakeAPIClient(result: .failure(GoogleCalendarAPIError.proxyGoogleAuthenticationRequired))
            let provider = makeProvider(connection: connection, direct: FakeDirectProvider(), apiClient: apiClient)

            for restore in [true, false] {
                let error = await #expect(throws: GoogleCalendarAPIError.self) {
                    if restore {
                        try await provider.restorePreviousSignIn()
                    } else {
                        try await provider.signIn(withPresentingWindow: NSWindow(), requestedScopes: GoogleOAuthScope.calendar)
                    }
                }
                #expect(error?.errorDescription == L10n.googleDatabricksReauthenticationRequired)
            }
            #expect(apiClient.sessions.count == 2)
        }

        @Test
        func signInSurfacesGoogleErrorsWithoutOpeningTheBrowser() async throws {
            let apiClient = FakeAPIClient(result: .failure(Self.googleRateLimit))
            let provider = makeProvider(connection: connection, direct: FakeDirectProvider(), apiClient: apiClient)

            await #expect(throws: GoogleCalendarAPIError.self) {
                try await provider.signIn(withPresentingWindow: NSWindow(), requestedScopes: GoogleOAuthScope.calendar)
            }
            #expect(apiClient.sessions.count == 1)
        }

        @Test
        func signInWithExistingGrantSkipsTheBrowser() async throws {
            let apiClient = FakeAPIClient(result: .success([Self.primaryCalendar]))
            let provider = makeProvider(connection: connection, direct: FakeDirectProvider(), apiClient: apiClient)

            let session = try await provider.signIn(withPresentingWindow: NSWindow(), requestedScopes: GoogleOAuthScope.calendar)

            #expect(session.account.id == "me@example.com")
            #expect(apiClient.sessions.count == 1)
        }

        @Test
        func removingDatabricksConnectionNotifiesGoogleCalendarSession() async throws {
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = Self.credential }
            let service = DatabricksOAuthService(storage: memory.storage) { _ in throw CancellationError() }
            let direct = FakeDirectProvider()
            let provider = DatabricksProxyGoogleSignInProvider(
                direct: direct, oauth: service, storage: memory.storage,
                apiClient: FakeAPIClient(result: .success([])), userDefaults: makeDefaults()
            )
            _ = try await provider.restorePreviousSignIn()
            let (posts, continuation) = AsyncStream.makeStream(of: Void.self)
            let token = NotificationCenter.default.addObserver(
                forName: provider.sessionDidChangeNotification, object: nil, queue: .main
            ) { _ in continuation.yield() }
            defer { NotificationCenter.default.removeObserver(token) }

            try await service.remove(connectionID: connection.id)

            var iterator = posts.makeAsyncIterator()
            let delivered = await iterator.next()
            withExtendedLifetime(provider) { #expect(delivered != nil) }
        }

        @Test
        func forwardedGoogleRateLimitOnRestoreSurfacesAndRetries() async throws {
            let apiClient = FakeAPIClient(result: .failure(Self.googleRateLimit))
            let provider = makeProvider(connection: connection, direct: FakeDirectProvider(), apiClient: apiClient)

            await #expect(throws: GoogleCalendarAPIError.self) { try await provider.restorePreviousSignIn() }

            #expect(await provider.hasPreviousSignIn)
            apiClient.result = .success([Self.primaryCalendar])
            #expect(try await provider.restorePreviousSignIn().account.id == "me@example.com")
        }

        @Test
        func restoreResolvesAccountFromPrimaryCalendarAndProxyBaseURL() async throws {
            let apiClient = FakeAPIClient(result: .success([
                CalendarListItem(id: "other@example.com", title: "Other", colorHex: nil, isPrimary: false),
                CalendarListItem(id: "me@example.com", title: "me@example.com", colorHex: nil, isPrimary: true),
            ]))
            let provider = makeProvider(connection: connection, direct: FakeDirectProvider(), apiClient: apiClient)

            let session = try await provider.restorePreviousSignIn()

            #expect(session.account.id == "me@example.com")
            #expect(session.accessToken == "databricks-token")
            #expect(session.apiBaseURL == DatabricksProxyGoogleSignInProvider.proxyBaseURL(for: connection))
            #expect(apiClient.sessions.first?.apiBaseURL == session.apiBaseURL)
        }

        @Test(arguments: [false, true])
        func onlyAPrimaryCalendarVerifiesTheProxyGoogleIdentity(hasPrimary: Bool) async throws {
            let calendar = CalendarListItem(id: "shared@example.com", title: "Shared", colorHex: nil, isPrimary: hasPrimary)
            let provider = makeProvider(connection: connection, direct: FakeDirectProvider(), apiClient: FakeAPIClient(result: .success([calendar])))
            let session = try await provider.restorePreviousSignIn()
            #expect(session.isAccountIdentityVerified == hasPrimary)
            #expect(session.account.id == calendar.id)
        }

        @Test
        func restoreWithoutDatabricksCredentialNeverOpensTheBrowser() async throws {
            let memory = DatabricksTestStorage(connection: connection)
            let authorized = Mutex(false)
            let service = DatabricksOAuthService(storage: memory.storage) { _ in
                authorized.withLock { $0 = true }
                throw CancellationError()
            }
            let provider = DatabricksProxyGoogleSignInProvider(
                direct: FakeDirectProvider(), oauth: service, storage: memory.storage,
                apiClient: FakeAPIClient(result: .success([])), userDefaults: makeDefaults()
            )

            let error = await #expect(throws: GoogleSignInError.self) { try await provider.restorePreviousSignIn() }
            #expect(error?.errorDescription == L10n.googleAccountNoPreviousSession)

            #expect(authorized.withLock { $0 } == false)
        }

        @Test
        func refreshResolvesTheCurrentAccountAgain() async throws {
            let apiClient = FakeAPIClient(result: .success([Self.primaryCalendar]))
            let provider = makeProvider(connection: connection, direct: FakeDirectProvider(), apiClient: apiClient)

            let restored = try await provider.restorePreviousSignIn()
            let refreshed = try await provider.refreshCurrentSession()

            #expect(refreshed?.account == restored.account)
            #expect(apiClient.sessions.count == 2)
        }

        @Test
        func disconnectStopsProxyUseUntilConnectAndKeepsTheDirectSession() async throws {
            let defaults = makeDefaults()
            let direct = FakeDirectProvider()
            let apiClient = FakeAPIClient(result: .success([Self.primaryCalendar]))
            let provider = makeProvider(connection: connection, direct: direct, userDefaults: defaults, apiClient: apiClient)

            #expect(provider.restoresThroughProxy)
            try await provider.disconnect()

            #expect(direct.disconnectCallCount == 0)
            #expect(provider.restoresThroughProxy == false)
            #expect(await provider.hasPreviousSignIn == false)
            let error = await #expect(throws: GoogleSignInError.self) { try await provider.restorePreviousSignIn() }
            #expect(error?.errorDescription == L10n.googleAccountNoPreviousSession)
            #expect(try await provider.refreshCurrentSession() == nil)
            #expect(apiClient.sessions.isEmpty)

            _ = try await provider.signIn(withPresentingWindow: NSWindow(), requestedScopes: GoogleOAuthScope.calendar)

            #expect(await provider.hasPreviousSignIn)
            #expect(provider.restoresThroughProxy)
            #expect(defaults.object(forKey: DatabricksProxyGoogleSignInProvider.disconnectedKey(for: connection)) == nil)
        }

        @Test
        func disconnectIsScopedToTheConnection() async throws {
            let defaults = makeDefaults()
            defaults.set(true, forKey: DatabricksProxyGoogleSignInProvider.disconnectedKey(for: connection))
            let readded = DatabricksConnection(id: UUID(), host: connection.host)
            let provider = makeProvider(connection: readded, direct: FakeDirectProvider(), userDefaults: defaults)

            // Re-adding a connection does not select it implicitly; choosing it opts in to its new identity.
            defaults.set(readded.id.uuidString, forKey: GoogleCalendarProvider.userDefaultsKey)
            let readdedConnections = try [ProviderAccountDirectory.Connection(id: readded.id, workspaceURL: #require(URL(string: readded.host)))]
            #expect(await ProviderAccountDirectory.$connections.withValue(readdedConnections) { await provider.hasPreviousSignIn })
        }

        private static let primaryCalendar = CalendarListItem(id: "me@example.com", title: "me@example.com", colorHex: nil, isPrimary: true)

        /// The proxy's HTTP 200 JSON-RPC error for a user without a Google credential (observed 2026-11-06).
        private static let noGrant = GoogleCalendarAPIError.proxyError(
            errorCode: "UNAUTHENTICATED",
            message: "Credential for user identity('1') is not found for the connection 'system_ai_agent_google_calendar'. Please login first."
        )

        private static let googleRateLimit = GoogleCalendarAPIError.httpError(
            statusCode: 403,
            detail: #"{"error":{"code":403,"message":"Rate Limit Exceeded","errors":[{"reason":"userRateLimitExceeded"}]}}"#
        )

        private static func databricksError(_ statusCode: Int, _ errorCode: String, _ message: String) -> GoogleCalendarAPIError {
            .httpError(statusCode: statusCode, detail: #"{"error_code":"\#(errorCode)","message":"\#(message)"}"#)
        }

        private static let credential = DatabricksOAuthCredential(
            accessToken: "databricks-token",
            refreshToken: "refresh",
            expirationDate: Date().addingTimeInterval(3600),
            tokenEndpoint: URL(string: "https://example.cloud.databricks.com/oidc/v1/token")!
        )

        private func makeDefaults() -> UserDefaults {
            let suite = "DatabricksProxyGoogleSignInProviderTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set(proxyConnectionID.uuidString, forKey: GoogleCalendarProvider.userDefaultsKey)
            return defaults
        }

        private func makeProvider(
            connection: DatabricksConnection?,
            direct: FakeDirectProvider,
            userDefaults: UserDefaults? = nil,
            apiClient: FakeAPIClient = FakeAPIClient(result: .success([]))
        ) -> DatabricksProxyGoogleSignInProvider {
            let memory = DatabricksTestStorage(connection: connection)
            if let connection {
                memory.state.withLock { $0.credentials[connection.id] = Self.credential }
            }
            return DatabricksProxyGoogleSignInProvider(
                direct: direct,
                oauth: DatabricksOAuthService(storage: memory.storage) { _ in throw CancellationError() },
                storage: memory.storage,
                apiClient: apiClient,
                userDefaults: userDefaults ?? makeDefaults()
            )
        }
    }

    private final class SuspendedWorkspaceTokenURLProtocol: URLProtocol, @unchecked Sendable {
        // Foundation callbacks and test tasks exchange only Sendable completions through the mutex.
        static let pending = Mutex<[String: @Sendable () -> Void]>([:])
        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url!
            if url.path == "/oidc/v1/token" {
                let host = url.host!
                let fail: @Sendable () -> Void = { [self] in complete(status: 400) }
                Self.pending.withLock { $0[host] = fail }
            } else {
                #expect(url.path == "/oidc/.well-known/oauth-authorization-server")
                complete(status: 404)
            }
        }

        private func complete(status: Int) {
            client?.urlProtocol(
                self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        /// Complete explicitly even after cancellation, to exercise the service's cancellation boundary.
        override func stopLoading() {}
    }

    @MainActor
    private final class FakeAPIClient: GoogleCalendarAPIClientProviding {
        var result: Result<[CalendarListItem], Error>
        private(set) var sessions: [GoogleSession] = []

        init(result: Result<[CalendarListItem], Error>) { self.result = result }

        func fetchCalendarList(session: GoogleSession) async throws -> [CalendarListItem] {
            sessions.append(session)
            return try result.get()
        }

        func fetchUpcomingEvents(
            session _: GoogleSession,
            calendars _: [CalendarListItem],
            now _: Date,
            daysAhead _: Int
        ) async throws -> [CalendarEvent] { [] }
    }

    @MainActor
    private final class FakeDirectProvider: GoogleSignInProviding {
        let isConfigured: Bool
        let hasPreviousSignIn: Bool
        let sessionDidChangeNotification = Notification.Name("FakeDirectProvider.\(UUID().uuidString)")
        private(set) var restoreCallCount = 0
        private(set) var signInCallCount = 0
        private(set) var requestedScopes: Set<String>?
        private(set) var disconnectCallCount = 0
        var restoreError: (any Error)?
        var session = GoogleSession(
            account: GoogleCalendarAccount(id: "direct", displayName: "Direct", email: "direct@example.com"),
            accessToken: "direct-token",
            grantedScopes: GoogleOAuthScope.calendar
        )

        init(isConfigured: Bool = true, hasPreviousSignIn: Bool = false) {
            self.isConfigured = isConfigured
            self.hasPreviousSignIn = hasPreviousSignIn
        }

        func restorePreviousSignIn() async throws -> GoogleSession {
            restoreCallCount += 1
            if let restoreError { throw restoreError }
            return session
        }

        func signIn(withPresentingWindow _: NSWindow, requestedScopes: Set<String>) async throws -> GoogleSession {
            signInCallCount += 1
            self.requestedScopes = requestedScopes
            return session
        }

        func refreshCurrentSession() async throws -> GoogleSession? { session }
        func disconnect() async throws { disconnectCallCount += 1 }
    }
#endif
