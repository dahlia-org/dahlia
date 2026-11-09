import AppKit
import CryptoKit
import Foundation
import Synchronization

actor DatabricksOAuthService {
    static let shared = DatabricksOAuthService()
    static let clientID = "databricks-cli"
    static let scope = "offline_access all-apis"

    private let session: URLSession
    private let storage: DatabricksOAuthStorage
    private let authorize: OAuthLoopbackAuthorization
    private final class Pending: Sendable {
        let connectionID: UUID
        let task: Task<String, Error>
        let loginOnly: Bool
        let interactive: Bool
        let generation: UUID
        /// nil closes registration before the last waiter cancels the task outside the lock.
        private let waiters: Mutex<Set<UUID>?>

        init(connectionID: UUID, task: Task<String, Error>, loginOnly: Bool, interactive: Bool, generation: UUID, waiter: UUID) {
            self.connectionID = connectionID
            self.task = task
            self.loginOnly = loginOnly
            self.interactive = interactive
            self.generation = generation
            waiters = Mutex([waiter])
        }

        var isFinished: Bool { waiters.withLock { $0 == nil } }

        func addWaiter(_ id: UUID) -> Bool {
            waiters.withLock {
                guard $0 != nil else { return false }
                $0?.insert(id)
                return true
            }
        }

        func removeWaiter(_ id: UUID) {
            let shouldCancel = waiters.withLock {
                guard $0?.remove(id) != nil, $0?.isEmpty == true else { return false }
                $0 = nil
                return true
            }
            if shouldCancel { task.cancel() }
        }
    }

    /// One token operation per workspace at a time.
    private var pending: [UUID: Pending] = [:]
    /// Access tokens kept in memory so each Pi request skips the Keychain. Refresh tokens stay only in the Keychain:
    /// they are read once per refresh, and holding them in memory would only widen their exposure.
    private var accessTokens: [UUID: (token: String, expirationDate: Date)] = [:]
    private var generations: [UUID: UUID] = [:]

    init(
        session: URLSession = URLSession(configuration: .ephemeral, delegate: OAuthNoRedirectDelegate(), delegateQueue: nil),
        storage: DatabricksOAuthStorage = .local(),
        authorize: @escaping OAuthLoopbackAuthorization = DatabricksOAuthService.authorizeInBrowser
    ) {
        self.session = session
        self.storage = storage
        self.authorize = authorize
    }

    /// Connected workspaces, oldest first. Each one is its own Databricks account.
    func connections() throws -> [DatabricksConnection] { try storage.loadConnections() }

    /// The oldest connected workspace, which Google Calendar's Databricks proxy uses.
    func currentConnection() throws -> DatabricksConnection? { try connections().first }

    /// The HTTPS origin of a Databricks workspace. A link into the workspace (a page, `?o=<workspace ID>`) or a bare
    /// host names the same workspace; another scheme or credentials in the URL are refused.
    nonisolated func normalizedWorkspaceURL(_ value: String?) throws -> URL {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
              var components = URLComponents(string: value.contains("://") ? value : "https://" + value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil
        else {
            throw CodexConfigurationError.invalidDatabricksWorkspaceURL
        }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        if components.port == 443 {
            components.port = nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw CodexConfigurationError.invalidDatabricksWorkspaceURL
        }
        return url
    }

    func connection(id: UUID) throws -> DatabricksConnection {
        guard let connection = try connections().first(where: { $0.id == id }) else {
            throw DahliaCloudError.noCredential
        }
        return connection
    }

    func signIn(workspaceURL: String) async throws -> DatabricksConnection {
        let url = try normalizedWorkspaceURL(workspaceURL)
        if let connection = try connections().first(where: { $0.host == url.absoluteString }) {
            _ = try await accessToken(connectionID: connection.id, forceRefresh: true, loginOnly: true)
            // A repaired credential lets Google Calendar retry a proxy restore that failed on the old one.
            NotificationCenter.default.post(name: .databricksConnectionDidChange, object: nil)
            return connection
        }
        let connection = DatabricksConnection(id: .v7(), host: url.absoluteString)
        let credential = try await login(connection)
        try Task.checkCancellation()
        // Publish the connection only after its credential is durable.
        let existing = try connections()
        guard !existing.contains(where: { $0.host == connection.host }) else { throw DatabricksOAuthError.workspaceAlreadyConnected }
        try storage.saveCredential(connection.id, credential)
        do { try storage.saveConnections(existing + [connection]) } catch {
            try? storage.deleteCredential(connection.id)
            throw error
        }
        NotificationCenter.default.post(name: .databricksConnectionDidChange, object: nil)
        return connection
    }

    /// The connection with its user's email and workspace ID, fetched once from SCIM `Me` and saved with it.
    func identifiedConnection(id: UUID) async throws -> DatabricksConnection? {
        guard var connection = try connections().first(where: { $0.id == id }) else { return nil }
        guard connection.email == nil else { return connection }
        let token = try await accessToken(connectionID: connection.id, interactive: false)
        var request = try URLRequest(
            url: normalizedWorkspaceURL(connection.host).appending(path: "api/2.0/preview/scim/v2/Me"),
            timeoutInterval: 30
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct SCIMUser: Decodable { let userName: String? }
        connection.email = try JSONDecoder().decode(SCIMUser.self, from: data).userName
        connection.workspaceID = response.value(forHTTPHeaderField: "x-databricks-org-id")
        // A sign-out during the request leaves nothing to update.
        var all = try connections()
        guard let index = all.firstIndex(where: { $0.id == connection.id }) else { return nil }
        all[index] = connection
        try storage.saveConnections(all)
        return connection
    }

    func remove(connectionID: UUID) throws {
        _ = try connection(id: connectionID)
        generations[connectionID] = UUID()
        pending[connectionID]?.task.cancel()
        pending[connectionID] = nil
        // The row goes first, so a failed write leaves a listed account that still works.
        try storage.saveConnections(connections().filter { $0.id != connectionID })
        accessTokens[connectionID] = nil
        try storage.deleteCredential(connectionID)
        NotificationCenter.default.post(name: .databricksConnectionDidChange, object: nil)
    }

    /// `interactive: false` never opens the browser: a missing or unrefreshable credential throws instead.
    func accessToken(
        connectionID: UUID,
        forceRefresh: Bool = false,
        loginOnly: Bool = false,
        interactive: Bool = true
    ) async throws -> String {
        let connection = try connection(id: connectionID)
        try Task.checkCancellation()
        let waiter = UUID()
        if !interactive, let operation = pending[connectionID], operation.interactive, !operation.isFinished {
            // Observe an interactive operation without holding it: only interactive callers keep a browser login alive.
            let token = try await waitForToken(operation, waiter: nil)
            try Task.checkCancellation()
            _ = try self.connection(id: connectionID)
            return token
        }
        if let operation = pending[connectionID], operation.addWaiter(waiter) {
            if loginOnly, !operation.loginOnly {
                // An explicit sign-in must still open the browser after a pending refresh.
                _ = try? await waitForToken(operation, waiter: waiter)
                try Task.checkCancellation()
                if pending[connectionID]?.generation == operation.generation { pending[connectionID] = nil }
                return try await accessToken(connectionID: connectionID, forceRefresh: forceRefresh, loginOnly: true)
            }
            if interactive, !operation.interactive {
                // An unattended refresh must not deny this caller the browser login it may need.
                do {
                    let token = try await waitForToken(operation, waiter: waiter)
                    try Task.checkCancellation()
                    _ = try self.connection(id: connectionID)
                    return token
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    if pending[connectionID]?.generation == operation.generation { pending[connectionID] = nil }
                    return try await accessToken(connectionID: connectionID, forceRefresh: true, loginOnly: loginOnly)
                }
            }
            let token = try await waitForToken(operation, waiter: waiter)
            try Task.checkCancellation()
            _ = try self.connection(id: connectionID)
            return token
        }
        if !loginOnly, !forceRefresh, let cached = accessTokens[connectionID], cached.expirationDate.timeIntervalSinceNow > 60 {
            return cached.token
        }
        let old = try storage.loadCredential(connectionID)
        if !loginOnly, !forceRefresh, let old, old.expirationDate.timeIntervalSinceNow > 60 {
            accessTokens[connectionID] = (old.accessToken, old.expirationDate)
            return old.accessToken
        }
        let generation = UUID()
        generations[connectionID] = generation
        let task = Task {
            let updated: DatabricksOAuthCredential
            if !loginOnly, let old {
                do {
                    updated = try await self.requestToken(endpoint: old.tokenEndpoint, workspace: connection.host, parameters: [
                        "grant_type": "refresh_token", "client_id": Self.clientID, "refresh_token": old.refreshToken,
                    ], previousRefreshToken: old.refreshToken)
                } catch is CancellationError { throw CancellationError() } catch {
                    try Task.checkCancellation()
                    guard interactive else { throw error }
                    updated = try await self.login(connection)
                }
            } else {
                guard interactive else { throw DahliaCloudError.noCredential }
                updated = try await self.login(connection)
            }
            try Task.checkCancellation()
            guard self.generations[connectionID] == generation else { throw CancellationError() }
            _ = try self.connection(id: connectionID)
            try self.storage.saveCredential(connectionID, updated)
            self.accessTokens[connectionID] = (updated.accessToken, updated.expirationDate)
            return updated.accessToken
        }
        let operation = Pending(
            connectionID: connectionID, task: task, loginOnly: loginOnly, interactive: interactive, generation: generation, waiter: waiter
        )
        pending[connectionID] = operation
        let token = try await waitForToken(operation, waiter: waiter)
        try Task.checkCancellation()
        _ = try self.connection(id: connectionID)
        return token
    }

    /// A nil `waiter` observes the operation without keeping it from being cancelled.
    private func waitForToken(_ operation: Pending, waiter: UUID?) async throws -> String {
        defer {
            if let waiter { operation.removeWaiter(waiter) }
            if pending[operation.connectionID]?.generation == operation.generation, operation.isFinished {
                pending[operation.connectionID] = nil
            }
        }
        return try await withTaskCancellationHandler {
            let (results, continuation) = AsyncStream<Result<String, Error>>.makeStream()
            Task {
                await continuation.yield(operation.task.result)
                continuation.finish()
            }
            for await result in results {
                try Task.checkCancellation()
                return try result.get()
            }
            throw CancellationError()
        } onCancel: { if let waiter { operation.removeWaiter(waiter) } }
    }

    private func login(_ connection: DatabricksConnection) async throws -> DatabricksOAuthCredential {
        let endpoints = try await discover(workspace: connection.host)
        let verifier = Self.randomString(byteCount: 64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomString(byteCount: 32)
        let authorizationEndpoint = endpoints.authorizationEndpoint
        let (callback, redirectURI) = try await authorize { redirectURI in
            var url = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
            url.queryItems = [
                .init(name: "response_type", value: "code"), .init(name: "client_id", value: Self.clientID),
                .init(name: "redirect_uri", value: redirectURI), .init(name: "scope", value: Self.scope),
                .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
            ]
            return url.url!
        }
        try Task.checkCancellation()
        // The loopback parser returns a normalized URL without a port; the listener owns the redirect port.
        let code = try DahliaCloudService.authorizationCode(from: callback, expectedState: state)
        return try await requestToken(endpoint: endpoints.tokenEndpoint, workspace: connection.host, parameters: [
            "grant_type": "authorization_code", "code": code, "client_id": Self.clientID,
            "redirect_uri": redirectURI, "code_verifier": verifier,
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
        let host = try normalizedWorkspaceURL(workspace)
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

    static func makeCallbackServer() async throws -> (server: OAuthLoopbackRedirectServer, redirectURI: String) {
        guard let callback = await OAuthLoopbackRedirectServer.listenOnFreeDatabricksPort() else {
            throw DatabricksOAuthError.callbackUnavailable
        }
        return callback
    }

    private static func authorizeInBrowser(
        _ authorizationURL: @Sendable (_ redirectURI: String) throws -> URL
    ) async throws -> (callback: URL, redirectURI: String) {
        let (server, redirectURI) = try await makeCallbackServer()
        try Task.checkCancellation()
        let url = try authorizationURL(redirectURI)
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw DahliaCloudError.browserCouldNotOpen }
        return try await (callbackURL(from: server), redirectURI)
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

extension Notification.Name {
    static let databricksConnectionDidChange = Notification.Name("DatabricksConnectionDidChangeNotification")
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
