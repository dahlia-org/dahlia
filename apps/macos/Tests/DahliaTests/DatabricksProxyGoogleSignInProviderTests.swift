import AppKit
import Foundation
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    /// The Databricks connection the app's account uses for Google Calendar and Drive in these tests.
    private let proxyConnectionID = UUID()

    @MainActor
    @Suite(.providerAccounts([.init(id: proxyConnectionID, workspaceURL: URL(string: "https://example.cloud.databricks.com")!)]))
    struct DatabricksProxyGoogleSignInProviderTests {
        private let connection = DatabricksConnection(id: proxyConnectionID, host: "https://example.cloud.databricks.com")

        @Test(arguments: [false, true])
        func driveImportResolvesTheCurrentGoogleUserOnTheSameProxy(identityFails: Bool) async throws {
            let host = "grant-\(UUID().uuidString.lowercased()).example"
            let connection = DatabricksConnection(id: proxyConnectionID, host: "https://\(host)")
            ChangingDriveGrantURLProtocol.states.withLock { $0[host] = .init() }
            defer { ChangingDriveGrantURLProtocol.states.withLock { $0[host] = nil } }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ChangingDriveGrantURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = Self.credential }
            let client = GoogleDriveBackupClient(urlSession: transport)
            let provider = DatabricksProxyGoogleSignInProvider(
                sessionKind: .drive, direct: FakeDirectProvider(),
                oauth: DatabricksOAuthService(storage: memory.storage) { _ in throw CancellationError() },
                storage: memory.storage, driveClient: client, userDefaults: makeDefaults(),
                connectionChangeNotification: Notification.Name("DriveConnection.\(UUID())")
            )
            let model = GoogleDriveBackupModel(signIn: provider, client: client, routeChangeNotification: Notification.Name("DriveRoute.\(UUID())"))
            await model.refresh()
            #expect(model.account?.id == "A")
            let file = try #require(model.files.first)
            ChangingDriveGrantURLProtocol.states.withLock {
                $0[host]?.identity = "B"
                $0[host]?.fails = identityFails
            }
            let database = try AppDatabaseManager(path: ":memory:")
            let service = BackupService(
                dbQueue: database.dbQueue, applicationSupportURL: FileManager.default.temporaryDirectory.appending(path: "unused-\(UUID())")
            )
            await #expect(throws: (any Error).self) { try await model.importBackup(file, using: service) }
            #expect(model.files.isEmpty)
            #expect(!model.isAuthorized)
            let state = try #require(ChangingDriveGrantURLProtocol.states.withLock { $0[host] })
            #expect(state.aboutRequests == 2)
            #expect(state.downloads == 0)
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
        func driveReadsUseTheirOwnConnectionAndDisconnectFlag() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DriveIdentityURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let direct = FakeDirectProvider()
            let defaults = makeDefaults()
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = Self.credential }
            let provider = DatabricksProxyGoogleSignInProvider(
                sessionKind: .drive, direct: direct,
                oauth: DatabricksOAuthService(storage: memory.storage) { _ in throw CancellationError() },
                storage: memory.storage, driveClient: GoogleDriveBackupClient(urlSession: transport),
                userDefaults: defaults
            )
            let session = try await provider.restorePreviousSignIn()
            #expect(session.grantedScopes == GoogleOAuthScope.drive)
            #expect(session.account.email == "drive@example.com")
            #expect(session.apiBaseURL.absoluteString.hasSuffix("/connections/system_ai_agent_google_drive/proxy/"))
            #expect(direct.restoreCallCount == 0)
            try await provider.disconnect()
            #expect(defaults.bool(forKey: DatabricksProxyGoogleSignInProvider.disconnectedKey(for: connection, sessionKind: .drive)))
            #expect(!defaults.bool(forKey: DatabricksProxyGoogleSignInProvider.disconnectedKey(for: connection)))
            #expect(await provider.hasPreviousSignIn == false)
            #expect(direct.disconnectCallCount == 0)
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
        func calendarFollowsTheChosenProviderAndDriveKeepsTheConnection() async throws {
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
        func theChoiceFallsBackToTheAccountsConnectionWhenItIsGone() throws {
            let defaults = makeDefaults()
            let id = UUID.v7()
            try ProviderAccountDirectory.$connections.withValue([.init(
                id: id,
                workspaceURL: #require(URL(string: "https://dbc-1.cloud.databricks.com"))
            )]) {
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .databricks(connectionID: id))
                defaults.set("google", forKey: GoogleCalendarProvider.userDefaultsKey)
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .google)
                defaults.set(UUID.v7().uuidString, forKey: GoogleCalendarProvider.userDefaultsKey)
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .databricks(connectionID: id))
            }
            ProviderAccountDirectory.$connections.withValue([]) {
                #expect(GoogleCalendarProvider.current(defaults: defaults) == .google)
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
                forName: direct.sessionDidChangeNotification, object: nil, queue: .main
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

            // The re-added connection is the app account's connection, so the account must list it.
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

    private final class ChangingDriveGrantURLProtocol: URLProtocol, @unchecked Sendable {
        struct State: Sendable {
            var identity = "A"
            var fails = false
            var aboutRequests = 0
            var downloads = 0
        }

        static let states = Mutex<[String: State]>([:])
        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url!
            let about = url.path.hasSuffix("/about")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let download = query.contains { $0.name == "alt" && $0.value == "media" }
            let state = Self.states.withLock { states in
                if about { states[url.host!]?.aboutRequests += 1 }
                if download { states[url.host!]?.downloads += 1 }
                return states[url.host!]!
            }
            let status = about && state.fails ? 401 : 200
            let body: String
            if about {
                body = "{\"user\":{\"displayName\":\"Drive\",\"emailAddress\":\"drive@example.com\",\"permissionId\":\"\(state.identity)\"}}"
            } else {
                let parent = query.first { $0.name == "q" }?.value ?? ""
                let id = parent.contains("'root'") ? "dahlia" : parent.contains("'dahlia'") ? "backups" : "backup"
                let name = id == "backup" ? "backup.tar.gz" : id
                body = "{\"files\":[{\"id\":\"\(id)\",\"name\":\"\(name)\"}]}"
            }
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private final class DriveIdentityURLProtocol: URLProtocol, @unchecked Sendable {
        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url!
            #expect(url.path == "/api/2.0/unity-catalog/connections/system_ai_agent_google_drive/proxy/drive/v3/about")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer databricks-token")
            let body = #"{"user":{"displayName":"Drive","emailAddress":"drive@example.com","permissionId":"drive-user"}}"#
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

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
        private(set) var disconnectCallCount = 0
        private let session = GoogleSession(
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
            return session
        }

        func signIn(withPresentingWindow _: NSWindow, requestedScopes _: Set<String>) async throws -> GoogleSession { session }
        func refreshCurrentSession() async throws -> GoogleSession? { session }
        func disconnect() async throws { disconnectCallCount += 1 }
    }
#endif
