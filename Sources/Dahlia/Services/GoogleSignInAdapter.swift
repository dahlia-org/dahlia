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
        "https://www.googleapis.com/auth/calendar.readonly",
    ]
    static let drive: Set = [
        "https://www.googleapis.com/auth/drive.file",
    ]

    static func authorizationScopes(for requestedScopes: Set<String>) -> Set<String> {
        base.union(requestedScopes)
    }
}

enum GoogleAuthSessionKind: CaseIterable {
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

enum GoogleSignInError: LocalizedError {
    case notConfigured
    case missingPresentingWindow
    case noPreviousSignIn
    case invalidAuthorizationResponse
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
        case .invalidAuthorizationResponse, .invalidTokenResponse, .stateMismatch:
            L10n.googleAccountUnexpectedResponse
        case let .authorizationFailed(message):
            message
        }
    }
}

@MainActor
protocol GoogleSignInProviding: AnyObject {
    var isConfigured: Bool { get }
    var hasPreviousSignIn: Bool { get }
    var sessionDidChangeNotification: Notification.Name { get }

    func restorePreviousSignIn() async throws -> GoogleSession
    func signIn(withPresentingWindow window: NSWindow, requestedScopes: Set<String>) async throws -> GoogleSession
    func refreshCurrentSession() async throws -> GoogleSession?
    func disconnect() async throws
}

@MainActor
final class GoogleSignInAdapter: NSObject, GoogleSignInProviding {
    private static let legacyKeychainKey = "googleOAuthSession"
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
        storedSession != nil
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
        guard let storedSessionLookup else {
            throw GoogleSignInError.noPreviousSignIn
        }

        let refreshed = try await refreshedSession(from: storedSessionLookup.session)
        save(refreshed)
        deleteLegacySessionIfNeeded(storedSessionLookup)
        return refreshed.session
    }

    func signIn(withPresentingWindow window: NSWindow, requestedScopes: Set<String>) async throws -> GoogleSession {
        guard let clientID = GoogleCalendarConfiguration.clientID else {
            throw GoogleSignInError.notConfigured
        }

        let previousSessionLookup = storedSessionLookup
        let authorizationScopes = authorizationScopesForSignIn(requestedScopes: requestedScopes)
        let clientSecret = GoogleCalendarConfiguration.clientSecret
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
        save(session)
        if let previousSessionLookup {
            deleteLegacySessionIfNeeded(previousSessionLookup)
        }
        NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
        return session.session
    }

    func refreshCurrentSession() async throws -> GoogleSession? {
        guard let storedSessionLookup else {
            return nil
        }

        let refreshed = try await refreshedSession(from: storedSessionLookup.session)
        save(refreshed)
        deleteLegacySessionIfNeeded(storedSessionLookup)
        return refreshed.session
    }

    func disconnect() async throws {
        if let storedSessionLookup {
            try await revokeIfPossible(token: storedSessionLookup.session.refreshToken ?? storedSessionLookup.session.accessToken)
            KeychainService.delete(key: storedSessionLookup.keychainKey)
        }
        KeychainService.delete(key: sessionKind.keychainKey)
        NotificationCenter.default.post(name: sessionDidChangeNotification, object: nil)
    }

    private var storedSession: StoredGoogleSession? {
        storedSessionLookup?.session
    }

    private var storedSessionLookup: StoredGoogleSessionLookup? {
        if let session = Self.loadStoredSession(key: sessionKind.keychainKey) {
            return StoredGoogleSessionLookup(session: session, keychainKey: sessionKind.keychainKey)
        }

        guard let legacySession = Self.loadStoredSession(key: Self.legacyKeychainKey),
              sessionKind.canAdoptLegacySession(legacySession)
        else {
            return nil
        }
        return StoredGoogleSessionLookup(session: legacySession, keychainKey: Self.legacyKeychainKey)
    }

    private func save(_ session: StoredGoogleSession) {
        save(session, key: sessionKind.keychainKey)
    }

    private func save(_ session: StoredGoogleSession, key: String) {
        guard let data = try? JSONEncoder().encode(session),
              let json = String(data: data, encoding: .utf8)
        else { return }

        try? KeychainService.save(key: key, value: json)
    }

    private static func loadStoredSession(key: String) -> StoredGoogleSession? {
        guard let json = KeychainService.load(key: key),
              let data = json.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(StoredGoogleSession.self, from: data)
    }

    private func deleteLegacySessionIfNeeded(_ lookup: StoredGoogleSessionLookup) {
        guard lookup.keychainKey == Self.legacyKeychainKey else { return }
        // 旧セッションは Calendar/Drive 共用の可能性があるため、削除する前に
        // 採用可能な他サービスのキーへ複製して、もう一方が締め出されるのを防ぐ。
        for kind in GoogleAuthSessionKind.allCases
            where kind != sessionKind
            && kind.canAdoptLegacySession(lookup.session)
            && Self.loadStoredSession(key: kind.keychainKey) == nil {
            save(lookup.session, key: kind.keychainKey)
        }
        KeychainService.delete(key: Self.legacyKeychainKey)
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

        let tokenResponse = try await refreshAccessToken(
            clientID: clientID,
            clientSecret: GoogleCalendarConfiguration.clientSecret,
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

    private func revokeIfPossible(token: String) async throws {
        var request = URLRequest(url: Self.revokeEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(["token": token]).data(using: .utf8)
        _ = try await urlSession.data(for: request)
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

    private static func extractAuthorizationCode(from callbackURL: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw GoogleSignInError.invalidAuthorizationResponse
        }

        let queryItems = Dictionary(
            uniqueKeysWithValues: components.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? []
        )
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

private struct StoredGoogleSession: Codable {
    let account: GoogleCalendarAccount
    let accessToken: String
    let refreshToken: String?
    let expirationDate: Date
    let grantedScopes: Set<String>

    var session: GoogleSession {
        GoogleSession(account: account, accessToken: accessToken, grantedScopes: grantedScopes)
    }
}

private struct StoredGoogleSessionLookup {
    let session: StoredGoogleSession
    let keychainKey: String
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

    static func generate() -> PKCE {
        let verifier = randomURLSafeString(length: 64)
        let challenge = Data(CryptoKit.SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        return PKCE(codeVerifier: verifier, codeChallenge: challenge)
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

private final class LoopbackRedirectServer: @unchecked Sendable {
    private(set) var redirectURL: URL

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.dahlia.google-oauth-loopback")
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var readinessContinuation: CheckedContinuation<Void, Error>?

    init() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
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
                    self?.readinessContinuation?.resume(throwing: error)
                    self?.readinessContinuation = nil
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            callbackContinuation = continuation
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                callbackContinuation?.resume(throwing: error)
                callbackContinuation = nil
                shutdown()
                return
            }

            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let url = parseRequestURL(from: request)
            else {
                reply(to: connection, status: "400 Bad Request", body: "Invalid OAuth redirect.")
                callbackContinuation?.resume(throwing: GoogleSignInError.invalidAuthorizationResponse)
                callbackContinuation = nil
                shutdown()
                return
            }

            reply(to: connection, status: "200 OK", body: "Dahlia authorization completed. You can close this window.")
            callbackContinuation?.resume(returning: url)
            callbackContinuation = nil
            shutdown()
        }
    }

    private func parseRequestURL(from request: String) -> URL? {
        guard let firstLine = request.split(separator: "\r\n").first else { return nil }
        let components = firstLine.split(separator: " ")
        guard components.count >= 2 else { return nil }
        let path = String(components[1])
        return URL(string: "http://127.0.0.1\(path)")
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
