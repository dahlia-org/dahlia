import AppKit
import Foundation

/// Routes Google Calendar through the Databricks Unity Catalog connection proxy when a Databricks
/// connection exists, and falls back to the direct Google OAuth adapter otherwise. The Google grant lives in
/// Databricks and is the source of truth: Dahlia restores whenever the proxy answers, unless the user disconnected.
@MainActor
final class DatabricksProxyGoogleSignInProvider: GoogleSignInProviding {
    static let connectionName = "system_ai_agent_google_calendar"
    /// Set per connection by Disconnect and cleared by Connect. The grant is shared with other Databricks agents,
    /// so Disconnect stops Dahlia's use without revoking it; a re-added workspace (new id) restores again.
    static func disconnectedKey(for connection: DatabricksConnection) -> String {
        "googleCalendarDatabricksProxyDisconnected.\(connection.id.uuidString)"
    }

    private let direct: any GoogleSignInProviding
    private let oauth: DatabricksOAuthService
    private let storage: DatabricksOAuthStorage
    private let apiClient: any GoogleCalendarAPIClientProviding
    private let userDefaults: UserDefaults
    private var cachedAccount: GoogleCalendarAccount?
    private var connectionObserver: GoogleAuthSessionObserver?

    init(
        direct: any GoogleSignInProviding = GoogleSignInAdapter(sessionKind: .calendar),
        oauth: DatabricksOAuthService = .shared,
        storage: DatabricksOAuthStorage = .local(),
        apiClient: any GoogleCalendarAPIClientProviding = GoogleCalendarAPIClient(),
        userDefaults: UserDefaults = .standard
    ) {
        self.direct = direct
        self.oauth = oauth
        self.storage = storage
        self.apiClient = apiClient
        self.userDefaults = userDefaults
        // Adding or removing the Databricks connection changes the route; the store re-evaluates through its own notification.
        connectionObserver = GoogleAuthSessionObserver(notificationName: .databricksConnectionDidChange) { [weak self] _ in
            guard let self else { return }
            cachedAccount = nil
            NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
        }
    }

    /// Only the /api/2.0 proxy route exists; /api/2.1 returns ENDPOINT_NOT_FOUND (verified 2026-11-05).
    static func proxyBaseURL(for connection: DatabricksConnection) -> URL {
        URL(string: connection.host + "/api/2.0/unity-catalog/connections/\(connectionName)/proxy/")!
    }

    static func signInPageURL(for connection: DatabricksConnection) -> URL {
        URL(string: connection.host + "/explore/connections/\(connectionName)")!
    }

    private var connection: DatabricksConnection? {
        try? storage.loadConnections().first
    }

    var isProxyActive: Bool { connection != nil }

    /// Where the user grants or fixes Google access for the active Databricks connection.
    var connectionPageURL: URL? { connection.map(Self.signInPageURL) }

    var isConfigured: Bool { isProxyActive || direct.isConfigured }

    private func isDisconnected(_ connection: DatabricksConnection) -> Bool {
        userDefaults.bool(forKey: Self.disconnectedKey(for: connection))
    }

    /// True while Dahlia restores through the proxy on every launch, whether or not that currently succeeds.
    var restoresThroughProxy: Bool {
        connection.map { !isDisconnected($0) } ?? false
    }

    var hasPreviousSignIn: Bool {
        get async {
            guard let connection else { return await direct.hasPreviousSignIn }
            return !isDisconnected(connection)
        }
    }

    var sessionDidChangeNotification: Notification.Name { direct.sessionDidChangeNotification }

    func restorePreviousSignIn() async throws -> GoogleSession {
        guard let connection else { return try await direct.restorePreviousSignIn() }
        guard !isDisconnected(connection) else { throw GoogleSignInError.noPreviousSignIn }
        do {
            return try await proxySession(for: connection, interactive: false)
        } catch let error where Self.isUnusableRoute(error) {
            // Restore runs for every Databricks connection, including users who never chose Calendar through it, so a
            // route this user cannot use stays signed out quietly; Connect's pre-check then reports why.
            throw GoogleSignInError.noPreviousSignIn
        }
    }

    func signIn(withPresentingWindow window: NSWindow, requestedScopes: Set<String>) async throws -> GoogleSession {
        guard let connection else {
            return try await direct.signIn(withPresentingWindow: window, requestedScopes: requestedScopes)
        }
        // Only this pre-check may open the Databricks login; every later token use is unattended.
        // Only a missing Google credential opens the page; any other error surfaces, and Settings then offers the page.
        if let session = try await proxySessionIfAuthorized(for: connection, interactive: true) {
            return markConnected(session, for: connection)
        }

        window.orderFrontRegardless()
        guard NSWorkspace.shared.open(Self.signInPageURL(for: connection)) else {
            throw DahliaCloudError.browserCouldNotOpen
        }
        // The proxy has no callback, so poll for up to 3 minutes while Databricks reports no Google credential.
        // Any other failure (e.g. 400 "Unable to load OAuth Config" on a vanity host) ends the wait and is shown.
        for _ in 0 ..< 60 {
            try await Task.sleep(for: .seconds(3))
            if let session = try await proxySessionIfAuthorized(for: connection) {
                NSApp.activate(ignoringOtherApps: true)
                return markConnected(session, for: connection)
            }
        }
        throw GoogleSignInError.authorizationTimedOut
    }

    func refreshCurrentSession() async throws -> GoogleSession? {
        guard let connection else { return try await direct.refreshCurrentSession() }
        guard !isDisconnected(connection) else { return nil }
        return try await proxySession(for: connection, account: cachedAccount, interactive: false)
    }

    func disconnect() async throws {
        guard let connection else { return try await direct.disconnect() }
        // The Google grant stays in Databricks; revoke it on the connection page.
        userDefaults.set(true, forKey: Self.disconnectedKey(for: connection))
        cachedAccount = nil
    }

    private func markConnected(_ session: GoogleSession, for connection: DatabricksConnection) -> GoogleSession {
        userDefaults.removeObject(forKey: Self.disconnectedKey(for: connection))
        NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
        return session
    }

    private func proxySessionIfAuthorized(
        for connection: DatabricksConnection,
        interactive: Bool = false
    ) async throws -> GoogleSession? {
        do {
            return try await proxySession(for: connection, interactive: interactive)
        } catch let error as GoogleCalendarAPIError where Self.isNotAuthorized(error) {
            return nil
        }
    }

    /// Resolves the account from the primary calendar when none is cached; the connection grants
    /// calendar.readonly only, so userinfo is unavailable.
    private func proxySession(
        for connection: DatabricksConnection,
        account: GoogleCalendarAccount? = nil,
        interactive: Bool
    ) async throws -> GoogleSession {
        let token = try await oauth.accessToken(connectionID: connection.id, interactive: interactive)
        func session(_ account: GoogleCalendarAccount) -> GoogleSession {
            GoogleSession(
                account: account,
                accessToken: token,
                grantedScopes: GoogleOAuthScope.calendar,
                apiBaseURL: Self.proxyBaseURL(for: connection)
            )
        }
        if let account { return session(account) }
        let placeholder = GoogleCalendarAccount(id: connection.host, displayName: L10n.googleCalendarUnknownAccount, email: "")
        let calendars = try await apiClient.fetchCalendarList(session: session(placeholder))
        let primary = calendars.first(where: \.isPrimary) ?? calendars.first
        let resolved = primary.map { GoogleCalendarAccount(id: $0.id, displayName: $0.title, email: "") } ?? placeholder
        cachedAccount = resolved
        return session(resolved)
    }

    /// A route Databricks rejected for this user: no Databricks credential, a Databricks token request rejected with a
    /// 4xx, a proxy JSON-RPC error, or a non-transient 4xx whose body is not Google's (404 RESOURCE_DOES_NOT_EXIST for a missing connection,
    /// 401/403 for a bad token, 400 on a vanity host). Google's forwarded errors, rate limits, 5xx, and network
    /// failures surface.
    static func isUnusableRoute(_ error: Error) -> Bool {
        switch error {
        case DahliaCloudError.noCredential:
            true
        case let DahliaCloudError.tokenRequestFailed(statusCode):
            isClientError(statusCode)
        case GoogleCalendarAPIError.proxyError:
            true
        case let error as GoogleCalendarAPIError:
            if case let .httpError(statusCode, _) = error { isClientError(statusCode) && !error.isGoogleError } else { false }
        default:
            false
        }
    }

    private static func isClientError(_ statusCode: Int) -> Bool {
        (400 ..< 500).contains(statusCode) && ![408, 429].contains(statusCode)
    }

    /// Unity Catalog has no Google credential for this user on the connection. Observed 2026-11-06: HTTP 200 with a
    /// JSON-RPC error whose error_code is UNAUTHENTICATED ("Credential for user identity('…') is not found for the
    /// connection '…'. Please login first …"). Bad Databricks tokens are real HTTP 401/403 and never match.
    static func isNotAuthorized(_ error: GoogleCalendarAPIError) -> Bool {
        if case .proxyError(errorCode: "UNAUTHENTICATED", _) = error { return true }
        return false
    }
}
