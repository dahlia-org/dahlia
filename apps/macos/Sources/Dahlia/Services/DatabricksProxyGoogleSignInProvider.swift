import AppKit
import Foundation

/// Routes Google Calendar and Drive reads through the provider the user chose for Google (`GoogleCalendarProvider`):
/// a Databricks connection's Unity Catalog proxy, or the direct Google OAuth adapter. The Google grant lives in Databricks and is the source of
/// truth: Dahlia restores
/// whenever the proxy answers, unless the user disconnected.
@MainActor
final class DatabricksProxyGoogleSignInProvider: GoogleSignInProviding {
    static let connectionName = "system_ai_agent_google_calendar"
    static let driveConnectionName = "system_ai_agent_google_drive"
    private let sessionKind: GoogleAuthSessionKind

    private static func connectionName(for kind: GoogleAuthSessionKind) -> String {
        kind == .drive ? driveConnectionName : connectionName
    }

    /// Set per connection by Disconnect and cleared by Connect. The grant is shared with other Databricks agents,
    /// so Disconnect stops Dahlia's use without revoking it; a re-added workspace (new id) restores again.
    static func disconnectedKey(for connection: DatabricksConnection, sessionKind: GoogleAuthSessionKind = .calendar) -> String {
        "\(sessionKind == .drive ? "googleDrive" : "googleCalendar")DatabricksProxyDisconnected.\(connection.id.uuidString)"
    }

    private let direct: any GoogleSignInProviding
    private let oauth: DatabricksOAuthService
    private let storage: DatabricksOAuthStorage
    private let driveClient: GoogleDriveBackupClient
    private let apiClient: any GoogleCalendarAPIClientProviding
    private let userDefaults: UserDefaults
    private var connectionObserver: GoogleAuthSessionObserver?
    private var directObserver: GoogleAuthSessionObserver?
    let sessionDidChangeNotification = Notification.Name("RoutedGoogleSession.\(UUID())")

    init(
        sessionKind: GoogleAuthSessionKind = .calendar,
        direct: (any GoogleSignInProviding)? = nil,
        oauth: DatabricksOAuthService = .shared,
        storage: DatabricksOAuthStorage = .local(),
        apiClient: any GoogleCalendarAPIClientProviding = GoogleCalendarAPIClient(),
        driveClient: GoogleDriveBackupClient = GoogleDriveBackupClient(),
        userDefaults: UserDefaults = .standard,
        connectionChangeNotification: Notification.Name = .databricksConnectionDidChange
    ) {
        self.sessionKind = sessionKind
        self.direct = direct ?? GoogleSignInAdapter(sessionKind: sessionKind)
        self.oauth = oauth
        self.storage = storage
        self.apiClient = apiClient
        self.driveClient = driveClient
        self.userDefaults = userDefaults
        directObserver = GoogleAuthSessionObserver(notificationName: self.direct.sessionDidChangeNotification) { [weak self] _ in
            guard let self, !isProxyActive else { return }
            // A queued hint must reconcile the current route; direct sign-out cleanup has its own observer.
            NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
        }
        // Provider credentials are independent: a direct Google sign-out must not disconnect a selected proxy.
        connectionObserver = GoogleAuthSessionObserver(notificationName: connectionChangeNotification) { [weak self] _ in
            guard let self else { return }
            NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
        }
    }

    /// Only the /api/2.0 proxy route exists; /api/2.1 returns ENDPOINT_NOT_FOUND (verified 2026-11-05).
    static func proxyBaseURL(for connection: DatabricksConnection, sessionKind: GoogleAuthSessionKind = .calendar) -> URL {
        URL(string: connection.host + "/api/2.0/unity-catalog/connections/\(connectionName(for: sessionKind))/proxy/")!
    }

    static func signInPageURL(for connection: DatabricksConnection, sessionKind: GoogleAuthSessionKind = .calendar) -> URL {
        URL(string: connection.host + "/explore/connections/\(connectionName(for: sessionKind))")!
    }

    private var connection: DatabricksConnection? {
        guard let connectionID = GoogleCalendarProvider.current(defaults: userDefaults).databricksConnectionID
        else { return nil }
        return try? storage.loadConnections().first { $0.id == connectionID }
    }

    var isProxyActive: Bool { connection != nil }

    /// Where the user grants or fixes Google access for the active Databricks connection.
    var connectionPageURL: URL? { connection.map { Self.signInPageURL(for: $0, sessionKind: sessionKind) } }

    var isConfigured: Bool { isProxyActive || direct.isConfigured }

    private func isDisconnected(_ connection: DatabricksConnection) -> Bool {
        userDefaults.bool(forKey: Self.disconnectedKey(for: connection, sessionKind: sessionKind))
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

    func restorePreviousSignIn() async throws -> GoogleSession {
        guard let connection else { return try await direct.restorePreviousSignIn() }
        guard !isDisconnected(connection) else { throw GoogleSignInError.noPreviousSignIn }
        do {
            return try await proxySession(for: connection, interactive: false)
        } catch let error where Self.isUnusableRoute(error) {
            // An unavailable explicitly selected route stays signed out; Connect reports the authorization error.
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
        guard NSWorkspace.shared.open(Self.signInPageURL(for: connection, sessionKind: sessionKind)) else {
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
        return try await proxySession(for: connection, interactive: false)
    }

    func disconnect() async throws {
        guard let connection else { return try await direct.disconnect() }
        // The Google grant stays in Databricks; revoke it on the connection page.
        userDefaults.set(true, forKey: Self.disconnectedKey(for: connection, sessionKind: sessionKind))
        NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
    }

    private func markConnected(_ session: GoogleSession, for connection: DatabricksConnection) -> GoogleSession {
        userDefaults.removeObject(forKey: Self.disconnectedKey(for: connection, sessionKind: sessionKind))
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

    /// Resolves the account from the primary calendar; the connection grants
    /// calendar.readonly only, so userinfo is unavailable.
    private func proxySession(
        for connection: DatabricksConnection,
        interactive: Bool
    ) async throws -> GoogleSession {
        let token = try await oauth.accessToken(connectionID: connection.id, interactive: interactive)
        func session(_ account: GoogleCalendarAccount) -> GoogleSession {
            GoogleSession(
                account: account,
                accessToken: token,
                grantedScopes: sessionKind.serviceScopes,
                apiBaseURL: Self.proxyBaseURL(for: connection, sessionKind: sessionKind)
            )
        }
        let placeholder = GoogleCalendarAccount(id: connection.host, displayName: L10n.googleCalendarUnknownAccount, email: "")
        if sessionKind == .drive {
            let resolved = try await driveClient.fetchAccount(session: session(placeholder))
            return session(resolved)
        }
        let calendars = try await apiClient.fetchCalendarList(session: session(placeholder))
        let primary = calendars.first(where: \.isPrimary)
        let displayed = primary ?? calendars.first
        let resolved = displayed.map { GoogleCalendarAccount(id: $0.id, displayName: $0.title, email: "") } ?? placeholder
        var result = session(resolved)
        result.isAccountIdentityVerified = primary != nil
        return result
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
