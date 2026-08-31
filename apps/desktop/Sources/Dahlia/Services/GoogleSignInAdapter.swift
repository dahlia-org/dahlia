import AppKit
import CryptoKit
import Foundation
import Network

struct GoogleSession: Equatable {
    let account: GoogleCalendarAccount
    let accessToken: String
    let grantedScopes: Set<String>

    func hasScopes(_ scopes: Set<String>) -> Bool {
        scopes.isSubset(of: grantedScopes)
    }
}

enum GoogleOAuthScope {
    static let base: Set = [
        "openid",
        "email",
        "profile",
    ]
    static let calendar: Set = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly",
    ]
    static let drive: Set = [
        "https://www.googleapis.com/auth/drive.file",
    ]

    static func authorizationScopes(for requestedScopes: Set<String>) -> Set<String> {
        base.union(requestedScopes)
    }
}

enum GoogleAuthSessionKind: CaseIterable, Sendable {
    case calendar
    case drive

    var keychainKey: String {
        switch self {
        case .calendar:
            "googleCalendarOAuthSession"
        case .drive:
            "googleDriveOAuthSession"
        }
    }

    var serviceScopes: Set<String> {
        switch self {
        case .calendar:
            GoogleOAuthScope.calendar
        case .drive:
            GoogleOAuthScope.drive
        }
    }

    var sessionDidChangeNotification: Notification.Name {
        switch self {
        case .calendar:
            .googleCalendarSessionDidChange
        case .drive:
            .googleDriveSessionDidChange
        }
    }

    fileprivate func canAdoptLegacySession(_ session: StoredGoogleSession) -> Bool {
        // 旧実装は Calendar/Drive のスコープを 1 つのセッションに union して保存していたため、
        // 完全一致ではなく「このサービスのスコープを含むか」で採用可否を判定する。
        serviceScopes.isSubset(of: session.grantedScopes)
    }
}

enum GoogleAuthSessionChangeReason: Equatable, Sendable {
    case disconnected
}

/// NotificationCenter owns and may release its opaque token off the main actor.
/// The buffered stream preserves notification order and returns to MainActor before touching Google account state.
final class GoogleAuthSessionObserver: @unchecked Sendable {
    private let token: NSObjectProtocol
    private let continuation: AsyncStream<Bool>.Continuation
    private let observationTask: Task<Void, Never>

    init(
        notificationName: Notification.Name,
        handler: @escaping @MainActor @Sendable (Bool) async -> Void
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        self.continuation = continuation
        token = NotificationCenter.default.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { notification in
            let forceSignOut = notification.object as? GoogleAuthSessionChangeReason == .disconnected
            continuation.yield(forceSignOut)
        }
        observationTask = Task { @MainActor in
            for await forceSignOut in stream {
                await handler(forceSignOut)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
        continuation.finish()
        observationTask.cancel()
    }
}

enum GoogleSignInError: LocalizedError {
    case notConfigured
    case missingPresentingWindow
    case noPreviousSignIn
    case invalidAuthorizationResponse
    case authorizationTimedOut
    case invalidTokenResponse
    case stateMismatch
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            L10n.googleAccountClientIDMissingMessage
        case .missingPresentingWindow:
            L10n.googleAccountMissingPresentingWindow
        case .noPreviousSignIn:
            L10n.googleAccountNoPreviousSession
        case .authorizationTimedOut:
            L10n.googleAccountAuthorizationTimedOut
        case .invalidAuthorizationResponse, .invalidTokenResponse, .stateMismatch:
            L10n.googleAccountUnexpectedResponse
        case let .authorizationFailed(message):
            message
        }
    }
}

actor GoogleKeychainWorker {
    private var generation: UInt64 = 0
    private var activeDisconnectCount = 0

    func perform<Value: Sendable>(_ operation: @Sendable () throws -> Value) rethrows -> Value {
        try operation()
    }

    func snapshot<Value: Sendable>(_ operation: @Sendable () throws -> Value) rethrows -> (Value, UInt64) {
        try (operation(), generation)
    }

    func performIfCurrent(generation expectedGeneration: UInt64, _ operation: @Sendable () throws -> Void) rethrows -> Bool {
        guard activeDisconnectCount == 0, generation == expectedGeneration else { return false }
        try operation()
        return true
    }

    func beginDisconnect() {
        generation &+= 1
        activeDisconnectCount += 1
    }

    func finishDisconnect() {
        activeDisconnectCount -= 1
        generation &+= 1
    }

    func isCurrent(generation expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration
    }
}

@MainActor
protocol GoogleSignInProviding: AnyObject {
    var isConfigured: Bool { get }
    var hasPreviousSignIn: Bool { get async }
    var sessionDidChangeNotification: Notification.Name { get }

    func restorePreviousSignIn() async throws -> GoogleSession
    func signIn(withPresentingWindow window: NSWindow, requestedScopes: Set<String>) async throws -> GoogleSession
    func refreshCurrentSession() async throws -> GoogleSession?
    func disconnect() async throws
}

@MainActor
final class GoogleSignInAdapter: NSObject, GoogleSignInProviding {
    private nonisolated static let legacyKeychainKey = "googleOAuthSession"
    private nonisolated static let keychainWorker = GoogleKeychainWorker()
    private static let disconnectPendingUserDefaultsKeyPrefix = "googleOAuthDisconnectPending"
    private static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    private static let userInfoEndpoint = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!
    private static let tokenRefreshLeeway: TimeInterval = 60

    private let sessionKind: GoogleAuthSessionKind
    private let urlSession: URLSession

    var isConfigured: Bool {
        GoogleCalendarConfiguration.isConfigured
    }

    var hasPreviousSignIn: Bool {
        get async {
            let disconnectPending = isDisconnectPending
            guard !disconnectPending else { return false }
            let sessionKind = sessionKind
            let hasStoredSession = await Self.loadStoredSessionSnapshot(sessionKind: sessionKind).lookup != nil
            return Self.shouldRestoreStoredSession(
                disconnectPending: isDisconnectPending,
                hasStoredSession: hasStoredSession
            )
        }
    }

    var sessionDidChangeNotification: Notification.Name {
        sessionKind.sessionDidChangeNotification
    }

    init(sessionKind: GoogleAuthSessionKind = .calendar, urlSession: URLSession = .shared) {
        self.sessionKind = sessionKind
        self.urlSession = urlSession
        super.init()
    }

    func restorePreviousSignIn() async throws -> GoogleSession {
        guard let storedSessionLookup = await storedSessionLookup() else {
            throw GoogleSignInError.noPreviousSignIn
        }

        let refreshed = try await refreshedSession(from: storedSessionLookup.session)
        guard !isDisconnectPending else {
            throw GoogleSignInError.noPreviousSignIn
        }
        guard await save(refreshed, migrating: storedSessionLookup, generation: storedSessionLookup.generation) else {
            throw GoogleSignInError.noPreviousSignIn
        }
        guard !isDisconnectPending else {
            throw GoogleSignInError.noPreviousSignIn
        }
        return refreshed.session
    }

    func signIn(withPresentingWindow window: NSWindow, requestedScopes: Set<String>) async throws -> GoogleSession {
        guard let clientID = GoogleCalendarConfiguration.clientID else {
            throw GoogleSignInError.notConfigured
        }

        let sessionKind = sessionKind
        let previousSessionSnapshot = await Self.loadStoredSessionSnapshot(sessionKind: sessionKind)
        let previousSessionLookup = isDisconnectPending ? nil : previousSessionSnapshot.lookup
        let authorizationScopes = authorizationScopesForSignIn(requestedScopes: requestedScopes)
        let clientSecret = await Self.loadClientSecret()
        let pkce = PKCE.generate()
        let state = PKCE.randomURLSafeString(length: 32)
        let redirectServer = try await LoopbackRedirectServer()
        let redirect = redirectServer.redirectURL
        let authorizationURL = Self.makeAuthorizationURL(
            clientID: clientID,
            redirectURL: redirect,
            codeChallenge: pkce.codeChallenge,
            state: state,
            scopes: authorizationScopes
        )

        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        guard NSWorkspace.shared.open(authorizationURL) else {
            throw GoogleSignInError.invalidAuthorizationResponse
        }

        let callbackURL = try await redirectServer.waitForCallback()
        NSApp.activate(ignoringOtherApps: true)

        let code = try Self.extractAuthorizationCode(from: callbackURL, expectedState: state)
        let tokenResponse = try await exchangeAuthorizationCode(
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURL: redirect,
            code: code,
            codeVerifier: pkce.codeVerifier
        )
        let account = try await fetchAccount(accessToken: tokenResponse.accessToken)
        let session = StoredGoogleSession(
            account: account,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? previousSessionLookup?.session.refreshToken,
            expirationDate: tokenResponse.expirationDate,
            grantedScopes: authorizationScopes
        )
        guard await save(session, migrating: previousSessionLookup, generation: previousSessionSnapshot.generation) else {
            throw CancellationError()
        }
        clearDisconnectPending()
        guard await Self.keychainWorker.isCurrent(generation: previousSessionSnapshot.generation) else {
            Self.markAllDisconnectsPending()
            throw CancellationError()
        }
        guard !isDisconnectPending else {
            throw CancellationError()
        }
        NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
        return session.session
    }

    func refreshCurrentSession() async throws -> GoogleSession? {
        guard let storedSessionLookup = await storedSessionLookup() else {
            return nil
        }

        let refreshed = try await refreshedSession(from: storedSessionLookup.session)
        guard !isDisconnectPending else { return nil }
        guard await save(refreshed, migrating: storedSessionLookup, generation: storedSessionLookup.generation) else { return nil }
        guard !isDisconnectPending else { return nil }
        return refreshed.session
    }

    func disconnect() async throws {
        Self.markAllDisconnectsPending()
        await Self.keychainWorker.beginDisconnect()
        var firstRevocationError: Error?
        for tokens in await Self.revocationTokensByAccount() {
            var accountWasRevoked = false
            var accountError: Error?
            for token in tokens {
                do {
                    try await revoke(token: token)
                    accountWasRevoked = true
                    break
                } catch {
                    accountError = accountError ?? error
                }
            }
            if !accountWasRevoked {
                firstRevocationError = firstRevocationError ?? accountError
            }
        }

        let deletionError: Error?
        do {
            try await clearAllStoredSessions()
            deletionError = nil
        } catch {
            deletionError = error
        }
        await Self.keychainWorker.finishDisconnect()
        if let deletionError {
            throw deletionError
        }
        if let firstRevocationError {
            throw firstRevocationError
        }
    }

    private func storedSessionLookup() async -> StoredGoogleSessionLookup? {
        guard !isDisconnectPending else { return nil }
        let sessionKind = sessionKind
        let snapshot = await Self.loadStoredSessionSnapshot(sessionKind: sessionKind)
        return isDisconnectPending ? nil : snapshot.lookup
    }

    private nonisolated static func loadStoredSessionSnapshot(
        sessionKind: GoogleAuthSessionKind
    ) async -> StoredGoogleSessionSnapshot {
        let (lookup, generation) = await keychainWorker.snapshot { () -> StoredGoogleSessionLookup? in
            if let session = loadStoredSession(key: sessionKind.keychainKey) {
                return StoredGoogleSessionLookup(session: session, keychainKey: sessionKind.keychainKey)
            }

            guard let legacySession = loadStoredSession(key: legacyKeychainKey),
                  sessionKind.canAdoptLegacySession(legacySession)
            else {
                return nil
            }
            return StoredGoogleSessionLookup(session: legacySession, keychainKey: legacyKeychainKey)
        }
        let currentLookup = lookup.map {
            StoredGoogleSessionLookup(session: $0.session, keychainKey: $0.keychainKey, generation: generation)
        }
        return StoredGoogleSessionSnapshot(lookup: currentLookup, generation: generation)
    }

    private func save(
        _ session: StoredGoogleSession,
        migrating lookup: StoredGoogleSessionLookup?,
        generation: UInt64
    ) async -> Bool {
        let key = sessionKind.keychainKey
        let sessionKind = sessionKind
        return await Self.save(session, key: key, migrating: lookup, sessionKind: sessionKind, generation: generation)
    }

    private nonisolated static func save(
        _ session: StoredGoogleSession,
        key: String,
        migrating lookup: StoredGoogleSessionLookup?,
        sessionKind: GoogleAuthSessionKind,
        generation: UInt64
    ) async -> Bool {
        let operation: @Sendable () -> Void = {
            saveStoredSession(session, key: key)
            guard let lookup, lookup.keychainKey == legacyKeychainKey else { return }

            // 旧セッションは Calendar/Drive 共用の可能性があるため、削除する前に
            // 採用可能な他サービスのキーへ複製して、もう一方が締め出されるのを防ぐ。
            for kind in GoogleAuthSessionKind.allCases
                where kind != sessionKind
                && kind.canAdoptLegacySession(lookup.session)
                && loadStoredSession(key: kind.keychainKey) == nil {
                saveStoredSession(lookup.session, key: kind.keychainKey)
            }
            KeychainService.delete(key: legacyKeychainKey)
        }
        return await keychainWorker.performIfCurrent(generation: generation, operation)
    }

    private nonisolated static func saveStoredSession(_ session: StoredGoogleSession, key: String) {
        guard let data = try? JSONEncoder().encode(session),
              let json = String(data: data, encoding: .utf8)
        else { return }

        try? KeychainService.save(key: key, value: json)
    }

    private nonisolated static func loadStoredSession(key: String) -> StoredGoogleSession? {
        guard let json = KeychainService.load(key: key),
              let data = json.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(StoredGoogleSession.self, from: data)
    }

    private var isDisconnectPending: Bool {
        UserDefaults.standard.bool(forKey: Self.disconnectPendingUserDefaultsKey(for: sessionKind))
    }

    private static func markAllDisconnectsPending() {
        for kind in GoogleAuthSessionKind.allCases {
            UserDefaults.standard.set(true, forKey: disconnectPendingUserDefaultsKey(for: kind))
        }
    }

    private func clearDisconnectPending() {
        // Explicit sign-in re-enables only the service the user just authorized.
        // The other service remains blocked until it receives its own consent.
        UserDefaults.standard.removeObject(forKey: Self.disconnectPendingUserDefaultsKey(for: sessionKind))
    }

    static func disconnectPendingUserDefaultsKey(for kind: GoogleAuthSessionKind) -> String {
        "\(disconnectPendingUserDefaultsKeyPrefix).\(kind.keychainKey)"
    }

    static func shouldRestoreStoredSession(disconnectPending: Bool, hasStoredSession: Bool) -> Bool {
        !disconnectPending && hasStoredSession
    }

    private nonisolated static func revocationTokensByAccount() async -> [[String]] {
        await keychainWorker.perform {
            let keys = [legacyKeychainKey] + GoogleAuthSessionKind.allCases.map(\.keychainKey)
            let sessions = keys.compactMap { key -> (accountID: String, token: String)? in
                guard let session = loadStoredSession(key: key) else { return nil }
                return (session.account.id, session.refreshToken ?? session.accessToken)
            }
            return groupRevocationTokens(sessions)
        }
    }

    nonisolated static func groupRevocationTokens(_ sessions: [(accountID: String, token: String)]) -> [[String]] {
        var tokensByAccount: [String: Set<String>] = [:]
        for session in sessions {
            tokensByAccount[session.accountID, default: []].insert(session.token)
        }
        return tokensByAccount.keys.sorted().compactMap { accountID in
            tokensByAccount[accountID]?.sorted()
        }
    }

    private func clearAllStoredSessions() async throws {
        defer {
            for kind in GoogleAuthSessionKind.allCases {
                NotificationCenter.default.post(
                    name: kind.sessionDidChangeNotification,
                    object: GoogleAuthSessionChangeReason.disconnected
                )
            }
        }
        try await Self.deleteAllStoredSessions()
    }

    private nonisolated static func deleteAllStoredSessions() async throws {
        try await keychainWorker.perform {
            let keys = [legacyKeychainKey] + GoogleAuthSessionKind.allCases.map(\.keychainKey)
            var firstError: Error?
            for key in keys {
                do {
                    try KeychainService.deleteOrThrow(key: key)
                } catch {
                    firstError = firstError ?? error
                }
            }
            if let firstError {
                throw firstError
            }
        }
    }

    private func authorizationScopesForSignIn(requestedScopes: Set<String>) -> Set<String> {
        GoogleOAuthScope.authorizationScopes(for: requestedScopes)
    }

    private func refreshedSession(from storedSession: StoredGoogleSession) async throws -> StoredGoogleSession {
        guard storedSession.expirationDate.timeIntervalSinceNow <= Self.tokenRefreshLeeway else {
            return storedSession
        }

        guard let clientID = GoogleCalendarConfiguration.clientID,
              let refreshToken = storedSession.refreshToken
        else {
            return storedSession
        }

        let clientSecret = await Self.loadClientSecret()
        let tokenResponse = try await refreshAccessToken(
            clientID: clientID,
            clientSecret: clientSecret,
            refreshToken: refreshToken
        )
        return StoredGoogleSession(
            account: storedSession.account,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? refreshToken,
            expirationDate: tokenResponse.expirationDate,
            grantedScopes: storedSession.grantedScopes
        )
    }

    private nonisolated static func loadClientSecret() async -> String? {
        await keychainWorker.perform {
            GoogleCalendarConfiguration.clientSecret
        }
    }

    private func exchangeAuthorizationCode(
        clientID: String,
        clientSecret: String?,
        redirectURL: URL,
        code: String,
        codeVerifier: String
    ) async throws -> TokenResponse {
        let body = Self.makeTokenRequestBody(
            clientID: clientID,
            clientSecret: clientSecret,
            parameters: [
                "code": code,
                "code_verifier": codeVerifier,
                "grant_type": "authorization_code",
                "redirect_uri": redirectURL.absoluteString,
            ]
        )
        return try await tokenRequest(body: body)
    }

    private func refreshAccessToken(clientID: String, clientSecret: String?, refreshToken: String) async throws -> TokenResponse {
        let body = Self.makeTokenRequestBody(
            clientID: clientID,
            clientSecret: clientSecret,
            parameters: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ]
        )
        return try await tokenRequest(body: body)
    }

    static func makeTokenRequestBody(
        clientID: String,
        clientSecret: String?,
        parameters: [String: String]
    ) -> [String: String] {
        var body = parameters
        body["client_id"] = clientID
        if let clientSecret, !clientSecret.isEmpty {
            body["client_secret"] = clientSecret
        }
        return body
    }

    private func tokenRequest(body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(body).data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleSignInError.invalidTokenResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let detail = Self.responseDetail(from: data) ?? L10n.googleAccountUnexpectedResponse
            throw GoogleSignInError.authorizationFailed(
                L10n.googleAccountHTTPError(httpResponse.statusCode, detail)
            )
        }

        let payload = try JSONDecoder().decode(TokenPayload.self, from: data)
        guard let expirationDate = Calendar.current.date(byAdding: .second, value: payload.expiresIn, to: Date()) else {
            throw GoogleSignInError.invalidTokenResponse
        }

        return TokenResponse(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expirationDate: expirationDate
        )
    }

    private func fetchAccount(accessToken: String) async throws -> GoogleCalendarAccount {
        var request = URLRequest(url: Self.userInfoEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleSignInError.invalidAuthorizationResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let detail = Self.responseDetail(from: data) ?? L10n.googleAccountUnexpectedResponse
            throw GoogleSignInError.authorizationFailed(
                L10n.googleAccountHTTPError(httpResponse.statusCode, detail)
            )
        }

        let payload = try JSONDecoder().decode(UserInfoPayload.self, from: data)
        return GoogleCalendarAccount(
            id: payload.subject,
            displayName: payload.name ?? payload.email ?? L10n.googleAccountUnknown,
            email: payload.email ?? ""
        )
    }

    private func revoke(token: String) async throws {
        var request = URLRequest(url: Self.revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(["token": token]).data(using: .utf8)
        let (data, response) = try await urlSession.data(for: request)
        try Self.validateRevocationResponse(response, data: data)
    }

    static func validateRevocationResponse(_ response: URLResponse, data: Data = Data()) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleSignInError.invalidAuthorizationResponse
        }
        if httpResponse.statusCode == 400, responseDetail(from: data) == "invalid_token" {
            return
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw GoogleSignInError.authorizationFailed(
                L10n.googleAccountHTTPError(httpResponse.statusCode, L10n.googleAccountUnexpectedResponse)
            )
        }
    }

    private static func makeAuthorizationURL(
        clientID: String,
        redirectURL: URL,
        codeChallenge: String,
        state: String,
        scopes: Set<String>
    ) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURL.absoluteString),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.sorted().joined(separator: " ")),
            .init(name: "access_type", value: "offline"),
            .init(name: "include_granted_scopes", value: "true"),
            .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: codeChallenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return components.url!
    }

    static func extractAuthorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard callbackURL.host == "127.0.0.1",
              callbackURL.path == "/oauth2redirect",
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw GoogleSignInError.invalidAuthorizationResponse
        }

        var queryItems: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, queryItems[item.name] == nil else {
                throw GoogleSignInError.invalidAuthorizationResponse
            }
            queryItems[item.name] = value
        }
        if let error = queryItems["error"] {
            let description = queryItems["error_description"] ?? error
            throw GoogleSignInError.authorizationFailed(description)
        }

        guard queryItems["state"] == expectedState else {
            throw GoogleSignInError.stateMismatch
        }

        guard let code = queryItems["code"], !code.isEmpty else {
            throw GoogleSignInError.invalidAuthorizationResponse
        }

        return code
    }

    private static func formEncoded(_ parameters: [String: String]) -> String {
        parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(urlEncode(key))=\(urlEncode(value))"
            }
            .joined(separator: "&")
    }

    private static func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
    }

    private static func responseDetail(from data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }

        if let errorDescription = payload["error_description"] as? String {
            return errorDescription
        }
        if let error = payload["error"] as? String {
            return error
        }
        return String(data: data, encoding: .utf8)
    }
}

private struct StoredGoogleSession: Codable, Sendable {
    let account: GoogleCalendarAccount
    let accessToken: String
    let refreshToken: String?
    let expirationDate: Date
    let grantedScopes: Set<String>

    var session: GoogleSession {
        GoogleSession(account: account, accessToken: accessToken, grantedScopes: grantedScopes)
    }
}

private struct StoredGoogleSessionLookup: Sendable {
    let session: StoredGoogleSession
    let keychainKey: String
    let generation: UInt64

    init(session: StoredGoogleSession, keychainKey: String, generation: UInt64 = 0) {
        self.session = session
        self.keychainKey = keychainKey
        self.generation = generation
    }
}

private struct StoredGoogleSessionSnapshot: Sendable {
    let lookup: StoredGoogleSessionLookup?
    let generation: UInt64
}

private struct TokenPayload: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct TokenResponse {
    let accessToken: String
    let refreshToken: String?
    let expirationDate: Date
}

private struct UserInfoPayload: Decodable {
    let subject: String
    let name: String?
    let email: String?

    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case name
        case email
    }
}

private struct PKCE {
    let codeVerifier: String
    let codeChallenge: String

    static func generate() -> Self {
        let verifier = randomURLSafeString(length: 64)
        let challenge = Data(CryptoKit.SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        return Self(codeVerifier: verifier, codeChallenge: challenge)
    }

    fileprivate static func randomURLSafeString(length: Int) -> String {
        let bytes = (0 ..< length).map { _ in UInt8.random(in: 0 ... 255) }
        return Data(bytes).base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return allowed
    }()
}

enum GoogleOAuthLoopbackRequest: Equatable {
    case callback(URL)
    case unrelated
    case invalid
}

enum GoogleOAuthLoopbackRequestParser {
    static func parse(_ request: String) -> GoogleOAuthLoopbackRequest {
        guard let firstLine = request.split(separator: "\r\n").first else { return .invalid }
        let components = firstLine.split(separator: " ")
        guard components.count >= 2, components[0] == "GET" else { return .invalid }
        guard let url = URL(string: "http://127.0.0.1\(components[1])") else { return .invalid }
        guard url.path == "/oauth2redirect" else { return .unrelated }
        return .callback(url)
    }
}

private final class LoopbackRedirectServer: @unchecked Sendable {
    private static let callbackTimeout: TimeInterval = 300
    private static let maximumRequestLength = 16384
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private(set) var redirectURL: URL

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.dahlia.google-oauth-loopback")
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackResult: Result<URL, Error>?
    private var callbackCompleted = false
    private var callbackTimeoutWorkItem: DispatchWorkItem?
    private var readinessContinuation: CheckedContinuation<Void, Error>?

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        redirectURL = URL(string: "http://127.0.0.1")!

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readinessContinuation = continuation

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.readinessContinuation?.resume()
                    self?.readinessContinuation = nil
                case let .failed(error):
                    if let continuation = self?.readinessContinuation {
                        self?.readinessContinuation = nil
                        continuation.resume(throwing: error)
                    } else {
                        self?.completeCallback(with: .failure(error))
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }

            listener.start(queue: queue)
        }

        guard let port = listener.port?.rawValue else {
            throw GoogleSignInError.invalidAuthorizationResponse
        }

        redirectURL = URL(string: "http://127.0.0.1:\(port)/oauth2redirect")!
    }

    func waitForCallback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: GoogleSignInError.invalidAuthorizationResponse)
                        return
                    }
                    if let result = pendingCallbackResult {
                        pendingCallbackResult = nil
                        callbackCompleted = true
                        continuation.resume(with: result)
                    } else if callbackCompleted || callbackContinuation != nil {
                        continuation.resume(throwing: GoogleSignInError.invalidAuthorizationResponse)
                    } else {
                        callbackContinuation = continuation
                        let timeoutWorkItem = DispatchWorkItem { [weak self] in
                            self?.completeCallback(with: .failure(GoogleSignInError.authorizationTimedOut))
                        }
                        callbackTimeoutWorkItem = timeoutWorkItem
                        queue.asyncAfter(deadline: .now() + Self.callbackTimeout, execute: timeoutWorkItem)
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.queue.async { [weak self] in
                self?.completeCallback(with: .failure(CancellationError()))
            }
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulatedData: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumRequestLength) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                connection.cancel()
                completeCallback(with: .failure(error))
                return
            }

            var requestData = accumulatedData
            if let data { requestData.append(data) }
            guard requestData.count <= Self.maximumRequestLength else {
                reply(to: connection, status: "413 Payload Too Large", body: "OAuth redirect request is too large.")
                completeCallback(with: .failure(GoogleSignInError.invalidAuthorizationResponse))
                return
            }
            guard requestData.contains(Self.headerTerminator) || isComplete else {
                receiveRequest(on: connection, accumulatedData: requestData)
                return
            }
            guard let request = String(data: requestData, encoding: .utf8) else {
                reply(to: connection, status: "400 Bad Request", body: "Invalid OAuth redirect.")
                completeCallback(with: .failure(GoogleSignInError.invalidAuthorizationResponse))
                return
            }

            switch GoogleOAuthLoopbackRequestParser.parse(request) {
            case let .callback(url):
                reply(to: connection, status: "200 OK", body: "Dahlia authorization completed. You can close this window.")
                completeCallback(with: .success(url))
            case .unrelated:
                reply(to: connection, status: "404 Not Found", body: "Not found.")
            case .invalid:
                reply(to: connection, status: "400 Bad Request", body: "Invalid OAuth redirect.")
                completeCallback(with: .failure(GoogleSignInError.invalidAuthorizationResponse))
            }
        }
    }

    private func completeCallback(with result: Result<URL, Error>) {
        guard !callbackCompleted, pendingCallbackResult == nil else { return }
        callbackTimeoutWorkItem?.cancel()
        callbackTimeoutWorkItem = nil
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            callbackCompleted = true
            continuation.resume(with: result)
        } else {
            pendingCallbackResult = result
        }
        shutdown()
    }

    private func reply(to connection: NWConnection, status: String, body: String) {
        let response = """
        HTTP/1.1 \(status)
        Content-Type: text/plain; charset=utf-8
        Content-Length: \(body.utf8.count)
        Connection: close

        \(body)
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func shutdown() {
        listener.cancel()
    }
}

extension Notification.Name {
    static let googleCalendarSessionDidChange = Notification.Name("GoogleCalendarSessionDidChangeNotification")
    static let googleDriveSessionDidChange = Notification.Name("GoogleDriveSessionDidChangeNotification")
}
