import AppKit
import Foundation

/// Routes Google Calendar through the Databricks Unity Catalog connection proxy when a Databricks
/// connection exists, and falls back to the direct Google OAuth adapter otherwise.
@MainActor
final class DatabricksProxyGoogleSignInProvider: GoogleSignInProviding {
    static let connectionName = "system_ai_agent_google_calendar"
    /// Set per connection only after the user completed a proxy sign-in, so a Databricks connection alone never
    /// triggers Google calls and a re-added workspace starts signed out.
    static func connectedKey(for connection: DatabricksConnection) -> String {
        "googleCalendarDatabricksProxyConnected.\(connection.id.uuidString)"
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
        try? storage.loadConnection()
    }

    var isProxyActive: Bool { connection != nil }

    var isConfigured: Bool { isProxyActive || direct.isConfigured }

    private func isConnected(_ connection: DatabricksConnection) -> Bool {
        userDefaults.bool(forKey: Self.connectedKey(for: connection))
    }

    var hasPreviousSignIn: Bool {
        get async {
            guard let connection else { return await direct.hasPreviousSignIn }
            return isConnected(connection)
        }
    }

    var sessionDidChangeNotification: Notification.Name { direct.sessionDidChangeNotification }

    func restorePreviousSignIn() async throws -> GoogleSession {
        guard let connection else { return try await direct.restorePreviousSignIn() }
        guard isConnected(connection) else { throw GoogleSignInError.noPreviousSignIn }
        // A status code cannot tell a revoked grant from a forwarded Google rate limit, so restore keeps the sign-in
        // and surfaces the failure; Connect re-checks without a browser while the grant exists, and Disconnect forgets it.
        do {
            return try await proxySession(for: connection, interactive: false)
        } catch DahliaCloudError.noCredential {
            // The Databricks credential is gone, not the Google grant: stay signed out until the user reconnects.
            throw GoogleSignInError.noPreviousSignIn
        }
    }

    func signIn(withPresentingWindow window: NSWindow, requestedScopes: Set<String>) async throws -> GoogleSession {
        guard let connection else {
            return try await direct.signIn(withPresentingWindow: window, requestedScopes: requestedScopes)
        }
        // Only this pre-check may open the Databricks login; every later token use is unattended.
        if let session = try await proxySessionIfAuthorized(for: connection, interactive: true) {
            return markConnected(session, for: connection)
        }

        window.orderFrontRegardless()
        guard NSWorkspace.shared.open(Self.signInPageURL(for: connection)) else {
            throw DahliaCloudError.browserCouldNotOpen
        }
        // The proxy has no callback, so poll for up to 3 minutes until Databricks reports a Google authorization.
        // Transient failures keep polling; the last one is reported only if the deadline passes.
        var lastError: Error = GoogleSignInError.authorizationTimedOut
        for _ in 0 ..< 60 {
            try await Task.sleep(for: .seconds(3))
            do {
                if let session = try await proxySessionIfAuthorized(for: connection) {
                    NSApp.activate(ignoringOtherApps: true)
                    return markConnected(session, for: connection)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func refreshCurrentSession() async throws -> GoogleSession? {
        guard let connection else { return try await direct.refreshCurrentSession() }
        guard isConnected(connection) else { return nil }
        return try await proxySession(for: connection, account: cachedAccount, interactive: false)
    }

    func disconnect() async throws {
        guard let connection else { return try await direct.disconnect() }
        // The Google grant stays in Databricks; revoke it on the connection page.
        userDefaults.removeObject(forKey: Self.connectedKey(for: connection))
        cachedAccount = nil
    }

    private func markConnected(_ session: GoogleSession, for connection: DatabricksConnection) -> GoogleSession {
        userDefaults.set(true, forKey: Self.connectedKey(for: connection))
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

    // shortcut: the proxy's exact status for a user without a Google grant is unverified, so during sign-in only,
    // credential-shaped statuses (400 "Invalid Token", 401, 403) mean "not granted yet"; others surface. Narrow once observed.
    static func isNotAuthorized(_ error: GoogleCalendarAPIError) -> Bool {
        if case let .httpError(statusCode, _) = error { return [400, 401, 403].contains(statusCode) }
        return false
    }
}
