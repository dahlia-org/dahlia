import AppKit
import CryptoKit
import Foundation
import Network

struct DahliaCloudConfiguration: Equatable, Sendable {
    static let urlKey = "DAHLIA_CLOUD_URL"
    static let clientIDKey = "DAHLIA_CLOUD_OAUTH_CLIENT_ID"
    static let defaultClientID = "databricks-cli"

    let baseURL: URL
    let clientID: String

    static var current: Self? {
        make(
            urlString: Bundle.main.object(forInfoDictionaryKey: urlKey) as? String
                ?? ProcessInfo.processInfo.environment[urlKey],
            clientID: configuredClientID
        )
    }

    static var configuredClientID: String {
        let value = Bundle.main.object(forInfoDictionaryKey: clientIDKey) as? String
            ?? ProcessInfo.processInfo.environment[clientIDKey]
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? defaultClientID
    }

    static func make(urlString: String?, clientID: String?) -> Self? {
        guard let value = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host)),
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.path.isEmpty || url.path == "/",
              url.query == nil,
              url.fragment == nil,
              let clientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientID.isEmpty
        else {
            return nil
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = ""
        guard let normalizedURL = components?.url else { return nil }
        return Self(baseURL: normalizedURL, clientID: clientID)
    }

    var origin: String {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = ""
        return components.url!.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct DahliaCloudAccount: Codable, Equatable, Sendable {
    let id: String
    let name: String?
    let email: String?

    var displayName: String {
        name?.nilIfBlank ?? email?.nilIfBlank ?? L10n.dahliaUnknownAccount
    }
}

struct DahliaCloudCredential: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expirationDate: Date
    let resource: String
    let issuer: String
    let clientID: String
    let grantedScopes: Set<String>
    let tokenEndpoint: URL
    let revocationEndpoint: URL?
    let account: DahliaCloudAccount
}

struct DahliaCloudCredentialStorage: Sendable {
    let load: @Sendable () throws -> DahliaCloudCredential?
    let save: @Sendable (DahliaCloudCredential) throws -> Void
    let delete: @Sendable () throws -> Void

    static let keychain = Self(
        load: {
            guard let value = KeychainService.load(key: "dahliaCloudOAuthCredential"),
                  let data = value.data(using: .utf8)
            else { return nil }
            return try JSONDecoder().decode(DahliaCloudCredential.self, from: data)
        },
        save: { credential in
            let data = try JSONEncoder().encode(credential)
            guard let value = String(data: data, encoding: .utf8) else {
                throw DahliaCloudError.credentialStorageFailed
            }
            try KeychainService.save(key: "dahliaCloudOAuthCredential", value: value)
        },
        delete: {
            try KeychainService.deleteOrThrow(key: "dahliaCloudOAuthCredential")
        }
    )
}

enum DahliaCloudError: LocalizedError, Equatable {
    case notConfigured
    case invalidDiscovery
    case unsupportedAuthorizationServer
    case browserCouldNotOpen
    case authorizationTimedOut
    case invalidCallback
    case stateMismatch
    case authorizationDenied
    case tokenRequestFailed(Int)
    case invalidTokenResponse
    case identityRequestFailed(Int)
    case invalidIdentityResponse
    case noCredential
    case credentialStorageFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            L10n.dahliaServerNotConfigured
        case .browserCouldNotOpen:
            L10n.dahliaCloudBrowserCouldNotOpen
        case .authorizationTimedOut:
            L10n.dahliaAuthorizationTimedOut
        case .stateMismatch, .invalidCallback, .invalidDiscovery, .unsupportedAuthorizationServer:
            L10n.dahliaUnexpectedResponse
        case .invalidTokenResponse:
            L10n.dahliaCloudInvalidTokenResponse
        case .invalidIdentityResponse:
            L10n.dahliaCloudInvalidSessionResponse
        case .authorizationDenied:
            L10n.dahliaAuthorizationDenied
        case let .tokenRequestFailed(status), let .identityRequestFailed(status):
            L10n.dahliaHTTPError(status)
        case .noCredential:
            L10n.dahliaNotSignedIn
        case .credentialStorageFailed:
            L10n.dahliaCredentialStorageFailed
        }
    }
}

actor DahliaCloudService {
    static let shared = DahliaCloudService(configuration: .current)

    typealias AuthorizationHandler = @Sendable (URL) async throws -> URL

    private static let redirectURL = URL(string: "http://localhost:8020")!
    private static let refreshLeeway: TimeInterval = 60
    private static let identityScopes = ["openid", "profile", "email", "offline_access"]

    private var configuration: DahliaCloudConfiguration?
    private let session: URLSession
    private let storage: DahliaCloudCredentialStorage
    private let authorize: AuthorizationHandler
    private var credential: DahliaCloudCredential?
    private var didLoadCredential = false
    private var refreshTask: Task<String, Error>?

    init(
        configuration: DahliaCloudConfiguration?,
        session: URLSession = .shared,
        storage: DahliaCloudCredentialStorage = .keychain,
        authorize: @escaping AuthorizationHandler = DahliaCloudService.authorizeInBrowser
    ) {
        self.configuration = configuration
        self.session = session
        self.storage = storage
        self.authorize = authorize
    }

    var isConfigured: Bool { configuration != nil }

    func storedConnection() throws -> (account: DahliaCloudAccount, origin: String)? {
        try loadCredentialIfNeeded()
        guard let credential else { return nil }
        return (credential.account, Self.origin(for: credential.resource))
    }

    func signIn(configuration selectedConfiguration: DahliaCloudConfiguration? = nil) async throws -> DahliaCloudAccount {
        guard let configuration = selectedConfiguration ?? configuration else { throw DahliaCloudError.notConfigured }
        let discovery = try await discover(configuration: configuration)
        let pkce = CloudPKCE.generate()
        let state = CloudPKCE.randomURLSafeString(byteCount: 32)
        let scopes = Set(discovery.protectedResource.scopesSupported ?? [])
            .union(discovery.usesProxySession ? ["offline_access"] : Self.identityScopes)
            .subtracting(["all-apis"])
        let authorizationURL = try Self.authorizationURL(
            endpoint: discovery.authorizationServer.authorizationEndpoint,
            configuration: configuration,
            resource: discovery.protectedResource.resource,
            scopes: scopes,
            state: state,
            codeChallenge: pkce.challenge
        )
        let callback = try await authorize(authorizationURL)
        let code = try Self.authorizationCode(from: callback, expectedState: state)
        let token = try await requestToken(
            endpoint: discovery.authorizationServer.tokenEndpoint,
            parameters: [
                "client_id": configuration.clientID,
                "code": code,
                "code_verifier": pkce.verifier,
                "grant_type": "authorization_code",
                "redirect_uri": Self.redirectURL.absoluteString,
                "resource": discovery.protectedResource.resource,
                "scope": scopes.sorted().joined(separator: " "),
            ],
            allowedScopes: scopes
        )
        let account = try await fetchAccount(
            accessToken: token.accessToken,
            userInfoEndpoint: discovery.authorizationServer.userInfoEndpoint,
            baseURL: configuration.baseURL,
            usesProxySession: discovery.usesProxySession
        )
        let newCredential = DahliaCloudCredential(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expirationDate: token.expirationDate,
            resource: discovery.protectedResource.resource,
            issuer: discovery.authorizationServer.issuer,
            clientID: configuration.clientID,
            grantedScopes: token.scopes ?? scopes,
            tokenEndpoint: discovery.authorizationServer.tokenEndpoint,
            revocationEndpoint: discovery.authorizationServer.revocationEndpoint,
            account: account
        )
        try storage.save(newCredential)
        credential = newCredential
        self.configuration = configuration
        didLoadCredential = true
        return account
    }

    func validAccessToken() async throws -> String {
        try loadCredentialIfNeeded()
        guard let credential else { throw DahliaCloudError.noCredential }
        guard credential.expirationDate.timeIntervalSinceNow <= Self.refreshLeeway else {
            return credential.accessToken
        }
        guard credential.refreshToken != nil else { throw DahliaCloudError.noCredential }
        if let refreshTask { return try await refreshTask.value }

        let task = Task { try await self.refreshAndPersist(credential) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func signOut() async throws {
        try loadCredentialIfNeeded()
        guard let credential else { return }
        if let endpoint = credential.revocationEndpoint {
            try await revoke(
                credential.refreshToken ?? credential.accessToken,
                tokenTypeHint: credential.refreshToken == nil ? "access_token" : "refresh_token",
                clientID: credential.clientID,
                endpoint: endpoint
            )
        }
        try storage.delete()
        self.credential = nil
    }

    private func loadCredentialIfNeeded() throws {
        guard !didLoadCredential else { return }
        let storedCredential = try storage.load()
        if storedCredential?.clientID == (configuration?.clientID ?? DahliaCloudConfiguration.configuredClientID),
           storedCredential?.grantedScopes.contains("all-apis") != true {
            credential = storedCredential
        }
        didLoadCredential = true
    }

    private func refreshAndPersist(_ oldCredential: DahliaCloudCredential) async throws -> String {
        guard let refreshToken = oldCredential.refreshToken else { throw DahliaCloudError.noCredential }
        let token = try await requestToken(
            endpoint: oldCredential.tokenEndpoint,
            parameters: [
                "client_id": oldCredential.clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": oldCredential.resource,
                "scope": oldCredential.grantedScopes.sorted().joined(separator: " "),
            ],
            allowedScopes: oldCredential.grantedScopes
        )
        let updated = DahliaCloudCredential(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? refreshToken,
            expirationDate: token.expirationDate,
            resource: oldCredential.resource,
            issuer: oldCredential.issuer,
            clientID: oldCredential.clientID,
            grantedScopes: token.scopes ?? oldCredential.grantedScopes,
            tokenEndpoint: oldCredential.tokenEndpoint,
            revocationEndpoint: oldCredential.revocationEndpoint,
            account: oldCredential.account
        )
        try storage.save(updated)
        credential = updated
        return updated.accessToken
    }

    private func discover(configuration: DahliaCloudConfiguration) async throws -> CloudDiscovery {
        let protectedURL = configuration.baseURL.appending(path: ".well-known/oauth-protected-resource")
        let protectedResource: ProtectedResourceMetadata = try await getJSON(protectedURL, error: .invalidDiscovery)
        guard let resourceURL = URL(string: protectedResource.resource),
              Self.sameOrigin(resourceURL.absoluteString, configuration.origin),
              let issuer = protectedResource.authorizationServers.first,
              let issuerURL = URL(string: issuer),
              Self.isSecureEndpoint(issuerURL)
        else {
            throw DahliaCloudError.invalidDiscovery
        }
        let metadataURL = issuerURL.appending(path: ".well-known/oauth-authorization-server")
        let authorizationServer: AuthorizationServerMetadata = try await getJSON(
            metadataURL,
            error: .unsupportedAuthorizationServer
        )
        guard authorizationServer.issuer == issuer,
              Self.isSecureEndpoint(authorizationServer.authorizationEndpoint),
              Self.isSecureEndpoint(authorizationServer.tokenEndpoint),
              authorizationServer.userInfoEndpoint.map(Self.isSecureEndpoint) ?? true,
              authorizationServer.revocationEndpoint.map(Self.isSecureEndpoint) ?? true,
              authorizationServer.codeChallengeMethodsSupported?.contains("S256") == true,
              authorizationServer.userInfoEndpoint != nil || Self.isRootResource(resourceURL)
        else {
            throw DahliaCloudError.unsupportedAuthorizationServer
        }
        return CloudDiscovery(protectedResource: protectedResource, authorizationServer: authorizationServer)
    }

    private func requestToken(
        endpoint: URL,
        parameters: [String: String],
        allowedScopes: Set<String>
    ) async throws -> CloudTokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(parameters).data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DahliaCloudError.invalidTokenResponse }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw DahliaCloudError.tokenRequestFailed(response.statusCode)
        }
        guard let payload = try? JSONDecoder().decode(CloudTokenPayload.self, from: data),
              payload.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              payload.expiresIn > 0
        else {
            throw DahliaCloudError.invalidTokenResponse
        }
        let returnedScopes = payload.scope.map { Set($0.split(separator: " ").map(String.init)) }
        guard returnedScopes?.isSubset(of: allowedScopes) != false,
              returnedScopes?.contains("all-apis") != true
        else {
            throw DahliaCloudError.invalidTokenResponse
        }
        return CloudTokenResponse(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expirationDate: Date().addingTimeInterval(TimeInterval(payload.expiresIn)),
            scopes: returnedScopes
        )
    }

    private func fetchAccount(
        accessToken: String,
        userInfoEndpoint: URL?,
        baseURL: URL,
        usesProxySession: Bool
    ) async throws -> DahliaCloudAccount {
        guard userInfoEndpoint != nil || usesProxySession else { throw DahliaCloudError.unsupportedAuthorizationServer }
        let endpoint = userInfoEndpoint ?? baseURL.appending(path: "api/session")
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DahliaCloudError.invalidIdentityResponse }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw DahliaCloudError.identityRequestFailed(response.statusCode)
        }
        if userInfoEndpoint != nil,
           let payload = try? JSONDecoder().decode(UserInfoPayload.self, from: data) {
            return DahliaCloudAccount(id: payload.subject, name: payload.name, email: payload.email)
        }
        guard let payload = try? JSONDecoder().decode(SessionPayload.self, from: data) else {
            throw DahliaCloudError.invalidIdentityResponse
        }
        return payload.user
    }

    private func revoke(_ token: String, tokenTypeHint: String, clientID: String, endpoint: URL) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded([
            "client_id": clientID,
            "token": token,
            "token_type_hint": tokenTypeHint,
        ]).data(using: .utf8)
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode)
        else {
            throw DahliaCloudError.tokenRequestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func getJSON<Value: Decodable>(_ url: URL, error: DahliaCloudError) async throws -> Value {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode),
              let value = try? JSONDecoder().decode(Value.self, from: data)
        else {
            throw error
        }
        return value
    }

    static func authorizationURL(
        endpoint: URL,
        configuration: DahliaCloudConfiguration,
        resource: String,
        scopes: Set<String>,
        state: String,
        codeChallenge: String
    ) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw DahliaCloudError.unsupportedAuthorizationServer
        }
        components.queryItems = [
            .init(name: "client_id", value: configuration.clientID),
            .init(name: "redirect_uri", value: redirectURL.absoluteString),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.sorted().joined(separator: " ")),
            .init(name: "resource", value: resource),
            .init(name: "code_challenge", value: codeChallenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        guard let url = components.url else { throw DahliaCloudError.unsupportedAuthorizationServer }
        return url
    }

    static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        guard callback.host == "127.0.0.1",
              callback.path == "/",
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        else {
            throw DahliaCloudError.invalidCallback
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard let value = item.value, values[item.name] == nil else { throw DahliaCloudError.invalidCallback }
            values[item.name] = value
        }
        guard values["state"] == expectedState else { throw DahliaCloudError.stateMismatch }
        if values["error"] != nil { throw DahliaCloudError.authorizationDenied }
        guard let code = values["code"], !code.isEmpty else { throw DahliaCloudError.invalidCallback }
        return code
    }

    private static func sameOrigin(_ resource: String, _ origin: String) -> Bool {
        guard let resourceURL = URL(string: resource), let originURL = URL(string: origin) else { return false }
        return resourceURL.scheme?.lowercased() == originURL.scheme?.lowercased()
            && resourceURL.host?.lowercased() == originURL.host?.lowercased()
            && resourceURL.port == originURL.port
    }

    private static func origin(for resource: String) -> String {
        guard let url = URL(string: resource),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return resource }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? resource
    }

    private static func isSecureEndpoint(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            || (url.scheme?.lowercased() == "http" && ["127.0.0.1", "localhost"].contains(url.host?.lowercased()))
    }

    private static func isRootResource(_ url: URL) -> Bool {
        url.path.isEmpty || url.path == "/"
    }

    private static func formEncoded(_ parameters: [String: String]) -> String {
        parameters.sorted { $0.key < $1.key }.map { key, value in
            "\(formEncode(key))=\(formEncode(value))"
        }.joined(separator: "&")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func authorizeInBrowser(_ url: URL) async throws -> URL {
        let port = NWEndpoint.Port(rawValue: 8020)!
        let server: OAuthLoopbackRedirectServer
        do {
            server = try await OAuthLoopbackRedirectServer(port: port, callbackPath: "/")
        } catch {
            throw DahliaCloudError.browserCouldNotOpen
        }
        let opened = await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            return NSWorkspace.shared.open(url)
        }
        guard opened else { throw DahliaCloudError.browserCouldNotOpen }
        do {
            return try await server.waitForCallback()
        } catch is CancellationError {
            throw CancellationError()
        } catch GoogleSignInError.authorizationTimedOut {
            throw DahliaCloudError.authorizationTimedOut
        } catch {
            throw DahliaCloudError.invalidCallback
        }
    }
}

private struct CloudDiscovery {
    let protectedResource: ProtectedResourceMetadata
    let authorizationServer: AuthorizationServerMetadata

    var usesProxySession: Bool {
        authorizationServer.userInfoEndpoint == nil
            && URL(string: protectedResource.resource).map { $0.path.isEmpty || $0.path == "/" } == true
    }
}

private struct ProtectedResourceMetadata: Decodable {
    let resource: String
    let authorizationServers: [String]
    let scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}

private struct AuthorizationServerMetadata: Decodable {
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let revocationEndpoint: URL?
    let userInfoEndpoint: URL?
    let codeChallengeMethodsSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case userInfoEndpoint = "userinfo_endpoint"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
    }
}

private struct CloudTokenPayload: Decodable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresIn: Int
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }
}

private struct CloudTokenResponse {
    let accessToken: String
    let refreshToken: String?
    let expirationDate: Date
    let scopes: Set<String>?
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

private struct SessionPayload: Decodable {
    let user: DahliaCloudAccount
}

private struct CloudPKCE {
    let verifier: String
    let challenge: String

    static func generate() -> Self {
        let verifier = randomURLSafeString(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Self(verifier: verifier, challenge: Data(digest).base64URLEncoded)
    }

    static func randomURLSafeString(byteCount: Int) -> String {
        Data((0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncoded
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
