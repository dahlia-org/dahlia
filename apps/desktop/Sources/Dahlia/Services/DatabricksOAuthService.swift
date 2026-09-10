import AppKit
import CryptoKit
import Foundation
import Network

actor DatabricksOAuthService {
    static let shared = DatabricksOAuthService()
    static let clientID = "databricks-cli"
    static let redirectURI = "http://localhost:8020"
    static let scope = "offline_access all-apis"

    private let session: URLSession
    private let storage: DatabricksOAuthStorage
    private let authorize: @Sendable (URL) async throws -> URL
    private struct Pending {
        let task: Task<String, Error>
        let loginOnly: Bool
        let generation: UUID
    }

    private var pending: Pending?
    private var generation = UUID()

    init(
        session: URLSession = URLSession(configuration: .ephemeral, delegate: OAuthNoRedirectDelegate(), delegateQueue: nil),
        storage: DatabricksOAuthStorage = .local(),
        authorize: @escaping @Sendable (URL) async throws -> URL = DatabricksOAuthService.authorizeInBrowser
    ) {
        self.session = session
        self.storage = storage
        self.authorize = authorize
    }

    func currentConnection() throws -> DatabricksConnection? { try storage.loadConnection() }

    func connection(id: UUID) throws -> DatabricksConnection {
        guard let connection = try currentConnection(), connection.id == id else {
            throw DahliaCloudError.noCredential
        }
        return connection
    }

    func signIn(workspaceURL: String) async throws -> DatabricksConnection {
        let url = try CodexConfigurationManager().normalizedDatabricksWorkspaceURL(workspaceURL)
        if let connection = try currentConnection() {
            guard connection.host == url.absoluteString else { throw DatabricksOAuthError.workspaceAlreadyConnected }
            _ = try await accessToken(connectionID: connection.id, forceRefresh: true, loginOnly: true)
            return connection
        }
        let connection = DatabricksConnection(id: .v7(), host: url.absoluteString)
        let credential = try await login(connection)
        try Task.checkCancellation()
        // Publish the sole connection only after its credential is durable.
        guard try currentConnection() == nil else { throw DatabricksOAuthError.workspaceAlreadyConnected }
        try storage.saveCredential(connection.id, credential)
        do { try storage.saveConnection(connection) } catch {
            try? storage.deleteCredential(connection.id)
            throw error
        }
        return connection
    }

    func remove(connectionID: UUID) throws {
        _ = try connection(id: connectionID)
        generation = UUID()
        pending?.task.cancel()
        pending = nil
        try storage.deleteCredential(connectionID)
        try storage.saveConnection(nil)
    }

    func accessToken(connectionID: UUID, forceRefresh: Bool = false, loginOnly: Bool = false) async throws -> String {
        let connection = try connection(id: connectionID)
        try Task.checkCancellation()
        if let operation = pending {
            if loginOnly, !operation.loginOnly {
                // An explicit sign-in must still open the browser after a pending refresh.
                _ = try? await waitForToken(operation.task)
                try Task.checkCancellation()
                if pending?.generation == operation.generation { pending = nil }
                return try await accessToken(connectionID: connectionID, forceRefresh: forceRefresh, loginOnly: true)
            }
            let token = try await waitForToken(operation.task)
            try Task.checkCancellation()
            _ = try self.connection(id: connectionID)
            return token
        }
        let old = try storage.loadCredential(connectionID)
        if !loginOnly, !forceRefresh, let old, old.expirationDate.timeIntervalSinceNow > 60 {
            return old.accessToken
        }
        let generation = UUID()
        self.generation = generation
        let task = Task {
            let updated: DatabricksOAuthCredential
            if !loginOnly, let old {
                do {
                    updated = try await self.requestToken(endpoint: old.tokenEndpoint, workspace: connection.host, parameters: [
                        "grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": old.refreshToken,
                    ], previousRefreshToken: old.refreshToken)
                } catch is CancellationError { throw CancellationError() } catch {
                    try Task.checkCancellation()
                    updated = try await self.login(connection)
                }
            } else {
                updated = try await self.login(connection)
            }
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            _ = try self.connection(id: connectionID)
            try self.storage.saveCredential(connectionID, updated)
            return updated.accessToken
        }
        pending = Pending(task: task, loginOnly: loginOnly, generation: generation)
        defer { if self.generation == generation { pending = nil } }
        return try await withTaskCancellationHandler {
            let token = try await task.value
            try Task.checkCancellation()
            _ = try self.connection(id: connectionID)
            return token
        } onCancel: { task.cancel() }
    }

    private func waitForToken(_ task: Task<String, Error>) async throws -> String {
        let (results, continuation) = AsyncStream<Result<String, Error>>.makeStream()
        Task {
            await continuation.yield(task.result)
            continuation.finish()
        }
        for await result in results {
            try Task.checkCancellation()
            return try result.get()
        }
        throw CancellationError()
    }

    private func login(_ connection: DatabricksConnection) async throws -> DatabricksOAuthCredential {
        let endpoints = try await discover(workspace: connection.host)
        let verifier = Self.randomString(byteCount: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomString(byteCount: 32)
        var url = URLComponents(url: endpoints.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        url.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirectURI), .init(name: "scope", value: Self.scope),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        let callback = try await authorize(url.url!)
        try Task.checkCancellation()
        // The loopback parser returns a normalized URL without a port; the listener owns port 8020.
        let code = try DahliaCloudService.authorizationCode(from: callback, expectedState: state)
        return try await requestToken(endpoint: endpoints.tokenEndpoint, workspace: connection.host, parameters: [
            "grant_type": "authorization_code", "code": code, "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI, "code_verifier": verifier,
        ])
    }

    private struct Endpoints: Decodable {
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        enum CodingKeys: String, CodingKey {
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
        }
    }

    private func discover(workspace: String) async throws -> Endpoints {
        let host = try CodexConfigurationManager().normalizedDatabricksWorkspaceURL(workspace)
        do {
            let (data, response) = try await session.data(for: URLRequest(
                url: host.appending(path: "oidc/.well-known/oauth-authorization-server"),
                timeoutInterval: 15
            ))
            if let response = response as? HTTPURLResponse, response.statusCode == 200,
               let endpoints = try? JSONDecoder().decode(Endpoints.self, from: data),
               Self.validEndpoint(endpoints.authorizationEndpoint, workspace: workspace),
               Self.validEndpoint(endpoints.tokenEndpoint, workspace: workspace) {
                return endpoints
            }
        } catch is CancellationError { throw CancellationError() } catch { try Task.checkCancellation() }
        return Endpoints(authorizationEndpoint: host.appending(path: "oidc/v1/authorize"), tokenEndpoint: host.appending(path: "oidc/v1/token"))
    }

    private func requestToken(
        endpoint: URL,
        workspace: String,
        parameters: [String: String],
        previousRefreshToken: String? = nil
    ) async throws -> DatabricksOAuthCredential {
        guard Self.validEndpoint(endpoint, workspace: workspace) else { throw DahliaCloudError.invalidDiscovery }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = DahliaCloudService.formEncoded(parameters).data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DahliaCloudError.invalidTokenResponse }
        guard (200 ..< 300).contains(response.statusCode) else { throw DahliaCloudError.tokenRequestFailed(response.statusCode) }
        guard let payload = try? JSONDecoder().decode(TokenPayload.self, from: data),
              payload.tokenType.lowercased() == "bearer", !payload.accessToken.isEmpty, payload.expiresIn > 0,
              let refresh = payload.refreshToken ?? previousRefreshToken, !refresh.isEmpty,
              payload.scope.map({ Set($0.split(separator: " ")).isSuperset(of: ["all-apis", "offline_access"]) }) ?? true
        else { throw DahliaCloudError.invalidTokenResponse }
        return DatabricksOAuthCredential(
            accessToken: payload.accessToken,
            refreshToken: refresh,
            expirationDate: Date().addingTimeInterval(payload.expiresIn),
            tokenEndpoint: endpoint
        )
    }

    private struct TokenPayload: Decodable {
        let accessToken: String
        let refreshToken: String?
        let tokenType: String
        let expiresIn: Double
        let scope: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", tokenType = "token_type", expiresIn = "expires_in", scope
        }
    }

    private static func validEndpoint(_ url: URL, workspace: String) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.fragment == nil
            && DahliaCloudService.sameOrigin(url.absoluteString, workspace)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomString(byteCount: Int) -> String {
        base64URL(Data((0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max) }))
    }

    static func makeCallbackServer() async throws -> OAuthLoopbackRedirectServer {
        do {
            return try await OAuthLoopbackRedirectServer(port: NWEndpoint.Port(rawValue: 8020)!, callbackPath: "/")
        } catch {
            throw DatabricksOAuthError.callbackUnavailable
        }
    }

    private static func authorizeInBrowser(_ url: URL) async throws -> URL {
        let server = try await makeCallbackServer()
        try Task.checkCancellation()
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw DahliaCloudError.browserCouldNotOpen }
        return try await callbackURL(from: server)
    }

    static func callbackURL(from server: OAuthLoopbackRedirectServer) async throws -> URL {
        do {
            return try await server.waitForCallback()
        } catch GoogleSignInError.authorizationTimedOut {
            throw DatabricksOAuthError.authorizationTimedOut
        } catch GoogleSignInError.invalidAuthorizationResponse {
            throw DatabricksOAuthError.invalidAuthorizationResponse
        }
    }
}

enum DatabricksOAuthError: LocalizedError, Equatable {
    case callbackUnavailable
    case workspaceAlreadyConnected
    case authorizationTimedOut
    case invalidAuthorizationResponse

    var errorDescription: String? {
        switch self {
        case .callbackUnavailable: L10n.databricksCallbackUnavailable
        case .workspaceAlreadyConnected: L10n.databricksWorkspaceAlreadyConnected
        case .authorizationTimedOut: L10n.databricksAuthorizationTimedOut
        case .invalidAuthorizationResponse: L10n.databricksInvalidAuthorizationResponse
        }
    }
}

private final class OAuthNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
