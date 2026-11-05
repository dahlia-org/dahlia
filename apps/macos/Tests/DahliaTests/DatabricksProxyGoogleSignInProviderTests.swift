import AppKit
import Foundation
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct DatabricksProxyGoogleSignInProviderTests {
        private let connection = DatabricksConnection(id: UUID(), host: "https://example.cloud.databricks.com")

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
        func credentialErrorsMeanNoGoogleAuthorization() {
            for code in [400, 401, 403] {
                #expect(DatabricksProxyGoogleSignInProvider.isNotAuthorized(.httpError(statusCode: code, detail: "")))
            }
            for code in [404, 429, 500] {
                #expect(!DatabricksProxyGoogleSignInProvider.isNotAuthorized(.httpError(statusCode: code, detail: "")))
            }
            #expect(!DatabricksProxyGoogleSignInProvider.isNotAuthorized(.invalidResponse))
        }

        @Test
        func withoutDatabricksConnectionEverythingGoesToDirectProvider() async throws {
            let direct = FakeDirectProvider(isConfigured: false, hasPreviousSignIn: true)
            let provider = makeProvider(connection: nil, direct: direct)

            #expect(provider.isConfigured == false)
            #expect(provider.isProxyActive == false)
            #expect(await provider.hasPreviousSignIn == true)
            _ = try await provider.restorePreviousSignIn()
            try await provider.disconnect()
            #expect(direct.restoreCallCount == 1)
            #expect(direct.disconnectCallCount == 1)
        }

        @Test
        func databricksConnectionAloneDoesNotCountAsGoogleSignIn() async throws {
            let direct = FakeDirectProvider(isConfigured: false, hasPreviousSignIn: true)
            let provider = makeProvider(connection: connection, direct: direct)

            #expect(provider.isConfigured)
            #expect(await provider.hasPreviousSignIn == false)
            await #expect(throws: GoogleSignInError.self) { try await provider.restorePreviousSignIn() }
            #expect(try await provider.refreshCurrentSession() == nil)
            #expect(direct.restoreCallCount == 0)
        }

        @Test
        func removingDatabricksConnectionNotifiesGoogleCalendarSession() async throws {
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = Self.credential }
            let service = DatabricksOAuthService(storage: memory.storage) { _ in throw CancellationError() }
            let direct = FakeDirectProvider()
            let defaults = makeDefaults()
            defaults.set(true, forKey: DatabricksProxyGoogleSignInProvider.connectedKey(for: connection))
            let provider = DatabricksProxyGoogleSignInProvider(
                direct: direct, oauth: service, storage: memory.storage,
                apiClient: FakeAPIClient(result: .success([])), userDefaults: defaults
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
        func connectedFlagIsScopedToTheConnection() async throws {
            let defaults = makeDefaults()
            defaults.set(true, forKey: DatabricksProxyGoogleSignInProvider.connectedKey(for: connection))
            let other = DatabricksConnection(id: UUID(), host: connection.host)
            let provider = makeProvider(connection: other, direct: FakeDirectProvider(), userDefaults: defaults)

            #expect(await provider.hasPreviousSignIn == false)
            #expect(try await provider.refreshCurrentSession() == nil)
        }

        @Test
        func unauthorizedProxyOnRestoreForgetsTheSignIn() async throws {
            let defaults = makeDefaults()
            defaults.set(true, forKey: DatabricksProxyGoogleSignInProvider.connectedKey(for: connection))
            let provider = makeProvider(
                connection: connection,
                direct: FakeDirectProvider(),
                userDefaults: defaults,
                apiClient: FakeAPIClient(result: .failure(GoogleCalendarAPIError.httpError(statusCode: 401, detail: "")))
            )

            await #expect(throws: GoogleSignInError.self) { try await provider.restorePreviousSignIn() }

            #expect(defaults.bool(forKey: DatabricksProxyGoogleSignInProvider.connectedKey(for: connection)) == false)
        }

        @Test
        func restoreResolvesAccountFromPrimaryCalendarAndProxyBaseURL() async throws {
            let defaults = makeDefaults()
            defaults.set(true, forKey: DatabricksProxyGoogleSignInProvider.connectedKey(for: connection))
            let apiClient = FakeAPIClient(result: .success([
                CalendarListItem(id: "other@example.com", title: "Other", colorHex: nil, isPrimary: false),
                CalendarListItem(id: "me@example.com", title: "me@example.com", colorHex: nil, isPrimary: true),
            ]))
            let provider = makeProvider(connection: connection, direct: FakeDirectProvider(), userDefaults: defaults, apiClient: apiClient)

            let session = try await provider.restorePreviousSignIn()

            #expect(session.account.id == "me@example.com")
            #expect(session.accessToken == "databricks-token")
            #expect(session.apiBaseURL == DatabricksProxyGoogleSignInProvider.proxyBaseURL(for: connection))
            #expect(apiClient.sessions.first?.apiBaseURL == session.apiBaseURL)
        }

        @Test
        func restoreWithoutDatabricksCredentialNeverOpensTheBrowser() async throws {
            let defaults = makeDefaults()
            defaults.set(true, forKey: DatabricksProxyGoogleSignInProvider.connectedKey(for: connection))
            let memory = DatabricksTestStorage(connection: connection)
            let authorized = Mutex(false)
            let service = DatabricksOAuthService(storage: memory.storage) { _ in
                authorized.withLock { $0 = true }
                throw CancellationError()
            }
            let provider = DatabricksProxyGoogleSignInProvider(
                direct: FakeDirectProvider(), oauth: service, storage: memory.storage,
                apiClient: FakeAPIClient(result: .success([])), userDefaults: defaults
            )

            await #expect(throws: GoogleSignInError.self) { try await provider.restorePreviousSignIn() }

            #expect(authorized.withLock { $0 } == false)
            #expect(defaults.bool(forKey: DatabricksProxyGoogleSignInProvider.connectedKey(for: connection)))
        }

        @Test
        func refreshReusesTheResolvedAccountWithoutRefetchingCalendars() async throws {
            let defaults = makeDefaults()
            defaults.set(true, forKey: DatabricksProxyGoogleSignInProvider.connectedKey(for: connection))
            let apiClient = FakeAPIClient(result: .success([
                CalendarListItem(id: "me@example.com", title: "me@example.com", colorHex: nil, isPrimary: true),
            ]))
            let provider = makeProvider(connection: connection, direct: FakeDirectProvider(), userDefaults: defaults, apiClient: apiClient)

            let restored = try await provider.restorePreviousSignIn()
            let refreshed = try await provider.refreshCurrentSession()

            #expect(refreshed?.account == restored.account)
            #expect(apiClient.sessions.count == 1)
        }

        @Test
        func disconnectForgetsProxySignInOnly() async throws {
            let defaults = makeDefaults()
            defaults.set(true, forKey: DatabricksProxyGoogleSignInProvider.connectedKey(for: connection))
            let direct = FakeDirectProvider()
            let provider = makeProvider(connection: connection, direct: direct, userDefaults: defaults)

            try await provider.disconnect()

            #expect(defaults.bool(forKey: DatabricksProxyGoogleSignInProvider.connectedKey(for: connection)) == false)
            #expect(direct.disconnectCallCount == 0)
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

    @MainActor
    private final class FakeAPIClient: GoogleCalendarAPIClientProviding {
        private let result: Result<[CalendarListItem], Error>
        private(set) var sessions: [GoogleSession] = []

        init(result: Result<[CalendarListItem], Error>) { self.result = result }

        func fetchCalendarList(session: GoogleSession) async throws -> [CalendarListItem] {
            sessions.append(session)
            return try result.get()
        }

        func fetchUpcomingEvents(session _: GoogleSession, calendars _: [CalendarListItem], now _: Date, daysAhead _: Int) async throws -> [CalendarEvent] { [] }
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
