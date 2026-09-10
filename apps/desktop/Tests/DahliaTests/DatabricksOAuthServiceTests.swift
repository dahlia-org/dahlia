#if canImport(Testing)
    import CryptoKit
    import Foundation
    import Synchronization
    import Testing
    @testable import Dahlia

    final class DatabricksTestStorage: Sendable {
        struct State {
            var connection: DatabricksConnection?
            var credentials: [UUID: DatabricksOAuthCredential] = [:]
            var failSave = false
        }

        let state: Mutex<State>
        init(connection: DatabricksConnection? = nil) { state = Mutex(State(connection: connection)) }
        var storage: DatabricksOAuthStorage {
            DatabricksOAuthStorage(
                loadConnection: { self.state.withLock { $0.connection } },
                saveConnection: { connection in self.state.withLock { $0.connection = connection } },
                loadCredential: { id in self.state.withLock { $0.credentials[id] } },
                saveCredential: { id, token in
                    try self.state.withLock {
                        if $0.failSave { throw DahliaCloudError.credentialStorageFailed }
                        $0.credentials[id] = token
                    }
                },
                deleteCredential: { id in _ = self.state.withLock { $0.credentials.removeValue(forKey: id) } }
            )
        }
    }

    @Suite(.serialized)
    struct DatabricksOAuthServiceTests {
        static let host = "https://workspace.example.com"
        static let token = #"{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","expires_in":3600}"#

        @Test @MainActor func restoresSelectionAfterCancellationFollowingConnectionSave() async throws {
            let memory = DatabricksTestStorage()
            var storage = memory.storage
            let save = storage.saveConnection
            storage.saveConnection = { connection in
                try save(connection)
                withUnsafeCurrentTask { $0?.cancel() }
            }
            let session = makeSession { request in
                request.url!.path.contains(".well-known") ? (404, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: storage) { url in
                URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            }
            let controller = DatabricksAccountController(service: service)
            let signIn = Task { await controller.signIn(workspaceURL: Self.host) }
            #expect(await signIn.value == nil)
            let saved = try #require(memory.state.withLock { $0.connection })
            #expect(await controller.load() == saved.id.uuidString)
            #expect(controller.connection == saved)
        }

        @Test(arguments: [true, false])
        func pkceAndDiscoveryFallback(discovery: Bool) async throws {
            let memory = DatabricksTestStorage()
            let challenge = Mutex("")
            let requestCount = Mutex(0)
            let session = makeSession { request in
                requestCount.withLock { $0 += 1 }
                if request.url!.path.contains(".well-known") {
                    if discovery {
                        return (
                            200,
                            #"{"authorization_endpoint":"https://workspace.example.com/custom/authorize","token_endpoint":"https://workspace.example.com/custom/token"}"#
                        )
                    }
                    return (404, "")
                }
                #expect(request.url!.path == (discovery ? "/custom/token" : "/oidc/v1/token"))
                let values = form(request)
                #expect(values["client_id"] == "databricks-cli")
                #expect(values["grant_type"] == "authorization_code")
                #expect(values["redirect_uri"] == "http://localhost:8020")
                #expect(values["code"] == "code")
                let verifier = try #require(values["code_verifier"])
                #expect(verifier.count == 86)
                let digest = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                #expect(challenge.withLock { $0 } == digest)
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
                return (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage) { url in
                let values = query(url)
                #expect(url.path == (discovery ? "/custom/authorize" : "/oidc/v1/authorize"))
                #expect(values["scope"] == "offline_access all-apis")
                #expect(values["code_challenge_method"] == "S256")
                #expect(values["response_type"] == "code")
                #expect(values["redirect_uri"] == "http://localhost:8020")
                challenge.withLock { $0 = values["code_challenge"]! }
                return URL(string: "http://127.0.0.1/?code=code&state=\(values["state"]!)")!
            }
            let connection = try await service.signIn(workspaceURL: Self.host)
            #expect(try await service.accessToken(connectionID: connection.id) == "access")
            #expect(requestCount.withLock { $0 } == 2)
            #expect(memory.state.withLock { $0.credentials[connection.id]?.refreshToken } == "refresh")
        }

        @Test func rejectsMismatchedStateBeforeTokenExchange() async throws {
            let session = makeSession { _ in (404, "") }
            defer { session.invalidateAndCancel() }
            let memory = DatabricksTestStorage()
            let service = DatabricksOAuthService(session: session, storage: memory.storage) { _ in
                URL(string: "http://127.0.0.1/?code=code&state=wrong")!
            }
            await #expect(throws: DahliaCloudError.stateMismatch) {
                try await service.signIn(workspaceURL: Self.host)
            }
            #expect(try await service.currentConnection() == nil)
        }

        @Test(arguments: [true, false])
        func refreshRotatesOrRetainsRefreshToken(rotates: Bool) async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = credential() }
            let session = makeSession { request in
                let values = form(request)
                #expect(values == ["client_id": "databricks-cli", "grant_type": "refresh_token", "refresh_token": "old-refresh"])
                return (200, rotates ? Self.token : #"{"access_token":"access","token_type":"Bearer","expires_in":3600}"#)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage)
            #expect(try await service.accessToken(connectionID: connection.id, forceRefresh: true) == "access")
            #expect(memory.state.withLock { $0.credentials[connection.id]?.refreshToken } == (rotates ? "refresh" : "old-refresh"))
        }

        @Test func failedRefreshReauthenticatesAndPersists() async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = credential() }
            let logins = Mutex(0)
            let session = makeSession { request in
                if request.url!.path.contains(".well-known") { return (404, "") }
                return form(request)["grant_type"] == "refresh_token" ? (400, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage) { url in
                logins.withLock { $0 += 1 }
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            }
            #expect(try await service.accessToken(connectionID: connection.id, forceRefresh: true) == "access")
            #expect(logins.withLock { $0 } == 1)
        }

        @Test func keychainFailureDoesNotPublishNewTokenOrStartLogin() async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = credential()
                $0.failSave = true
            }
            let session = makeSession { _ in (200, Self.token) }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage) { _ in
                Issue.record("Storage failures must not trigger a browser login")
                throw CancellationError()
            }
            await #expect(throws: DahliaCloudError.credentialStorageFailed) {
                try await service.accessToken(connectionID: connection.id, forceRefresh: true)
            }
            #expect(memory.state.withLock { $0.credentials[connection.id]?.accessToken } == "old-access")
        }

        @Test func simultaneousTokenRequestsShareOneLogin() async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            let (reads, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            var storage = memory.storage
            storage.loadConnection = {
                continuation.yield(())
                return memory.state.withLock { $0.connection }
            }
            let gate = DatabricksAuthorizationGate()
            let logins = Mutex(0)
            let session = makeSession { request in
                request.url!.path.contains(".well-known") ? (404, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: storage) { url in
                logins.withLock { $0 += 1 }
                await gate.wait()
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            }
            let first = Task { try await service.accessToken(connectionID: connection.id, forceRefresh: true) }
            let second = Task { try await service.accessToken(connectionID: connection.id, forceRefresh: true) }
            var iterator = reads.makeAsyncIterator()
            _ = await iterator.next()
            _ = await iterator.next()
            await gate.release()
            #expect(try await first.value == "access")
            #expect(try await second.value == "access")
            #expect(logins.withLock { $0 } == 1)
        }

        @Test(arguments: [true, false])
        func cancelledOrRemovedConnectionCannotPublishLogin(removesConnection: Bool) async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            let gate = DatabricksAuthorizationGate()
            let (entered, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            let session = makeSession { request in
                request.url!.path.contains(".well-known") ? (404, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage) { url in
                continuation.yield(())
                await gate.wait() // Deliberately finish even if the caller cancels.
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            }
            let task = Task { try await service.accessToken(connectionID: connection.id) }
            var iterator = entered.makeAsyncIterator()
            _ = await iterator.next()
            if removesConnection {
                try await service.remove(connectionID: connection.id)
            } else {
                task.cancel()
            }
            await gate.release()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(memory.state.withLock { $0.credentials.isEmpty })
            #expect(try await service.currentConnection() == (removesConnection ? nil : connection))
        }

        @Test(arguments: [
            #"{"access_token":"access","refresh_token":"refresh","token_type":"Basic","expires_in":3600}"#,
            #"{"access_token":"access","token_type":"Bearer","expires_in":3600}"#,
            #"{"access_token":"","refresh_token":"refresh","token_type":"Bearer","expires_in":3600}"#,
            #"{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","expires_in":0}"#,
            #"{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","expires_in":3600,"scope":"serving"}"#,
        ])
        func rejectsUnusableTokenBeforeSaving(payload: String) async throws {
            let memory = DatabricksTestStorage()
            let session = makeSession { request in
                request.url!.path.contains(".well-known") ? (404, "") : (200, payload)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage) { url in
                URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            }
            await #expect(throws: DahliaCloudError.invalidTokenResponse) {
                try await service.signIn(workspaceURL: Self.host)
            }
            #expect(memory.state.withLock { $0.credentials.isEmpty && $0.connection == nil })
        }

        @Test func discoveryCannotSendCredentialsToAnotherOrigin() async throws {
            let memory = DatabricksTestStorage()
            let session = makeSession { request in
                #expect(request.url!.host == "workspace.example.com")
                if request.url!.path.contains(".well-known") {
                    return (
                        200,
                        #"{"authorization_endpoint":"https://evil.example.com/authorize","token_endpoint":"https://evil.example.com/token"}"#
                    )
                }
                #expect(request.url!.path == "/oidc/v1/token")
                return (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage) { url in
                #expect(url.host == "workspace.example.com")
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            }
            _ = try await service.signIn(workspaceURL: Self.host)
        }

        @Test func cancellingJoinedWaitLeavesOriginalLoginRunning() async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            let (reads, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            var storage = memory.storage
            storage.loadConnection = {
                continuation.yield(())
                return memory.state.withLock { $0.connection }
            }
            let gate = DatabricksAuthorizationGate()
            let session = makeSession { request in
                request.url!.path.contains(".well-known") ? (404, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: storage) { url in
                await gate.wait()
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            }
            let original = Task { try await service.accessToken(connectionID: connection.id) }
            var iterator = reads.makeAsyncIterator()
            _ = await iterator.next()
            let joined = Task { try await service.accessToken(connectionID: connection.id) }
            _ = await iterator.next()
            joined.cancel()
            await #expect(throws: CancellationError.self) { try await joined.value }
            #expect(memory.state.withLock { $0.credentials.isEmpty })
            await gate.release()
            #expect(try await original.value == "access")
        }

        @Test func explicitSignInWaitsForRefreshThenOpensBrowser() async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = credential() }
            let (reads, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            var storage = memory.storage
            storage.loadConnection = {
                continuation.yield(())
                return memory.state.withLock { $0.connection }
            }
            let releaseRefresh = DispatchSemaphore(value: 0)
            let (requests, requestContinuation) = AsyncStream<Void>.makeStream()
            defer { requestContinuation.finish() }
            let logins = Mutex(0)
            let session = makeSession { request in
                if request.url!.path.contains(".well-known") { return (404, "") }
                if form(request)["grant_type"] == "refresh_token" {
                    requestContinuation.yield(())
                    // URLProtocol's worker waits for the test's observable join, never MainActor.
                    #expect(releaseRefresh.wait(timeout: .now() + 5) == .success)
                }
                return (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: storage) { url in
                logins.withLock { $0 += 1 }
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            }
            let refresh = Task { try await service.accessToken(connectionID: connection.id, forceRefresh: true) }
            var requestIterator = requests.makeAsyncIterator()
            _ = await requestIterator.next()
            var readIterator = reads.makeAsyncIterator()
            _ = await readIterator.next()
            let signIn = Task { try await service.signIn(workspaceURL: Self.host) }
            _ = await readIterator.next() // signIn's existing-connection lookup
            _ = await readIterator.next() // accessToken joins the pending refresh
            releaseRefresh.signal()
            #expect(try await refresh.value == "access")
            #expect(try await signIn.value == connection)
            #expect(logins.withLock { $0 } == 1)
        }

        @Test func loopbackErrorsUseDatabricksMessagesAndPreserveCancellation() async throws {
            let expiring = try await OAuthLoopbackRedirectServer(callbackPath: "/", callbackTimeout: 0.01)
            await #expect(throws: DatabricksOAuthError.authorizationTimedOut) {
                try await DatabricksOAuthService.callbackURL(from: expiring)
            }
            #expect(DatabricksOAuthError.authorizationTimedOut.localizedDescription == L10n.databricksAuthorizationTimedOut)
            #expect(DatabricksOAuthError.authorizationTimedOut.localizedDescription.contains("Databricks"))
            // A completed server rejects a second waiter as an invalid authorization response.
            await #expect(throws: DatabricksOAuthError.invalidAuthorizationResponse) {
                try await DatabricksOAuthService.callbackURL(from: expiring)
            }
            #expect(DatabricksOAuthError.invalidAuthorizationResponse.localizedDescription == L10n.databricksInvalidAuthorizationResponse)
            #expect(DatabricksOAuthError.invalidAuthorizationResponse.localizedDescription.contains("Databricks"))
            let server = try await OAuthLoopbackRedirectServer(callbackPath: "/")
            let task = Task { try await DatabricksOAuthService.callbackURL(from: server) }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }

        @Test func oneWorkspaceRequiresSignOutBeforeSwitching() async throws {
            let memory = DatabricksTestStorage()
            let logins = Mutex(0)
            let session = makeSession { request in
                request.url!.path.contains(".well-known") ? (404, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage) { url in
                logins.withLock { $0 += 1 }
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            }
            let first = try await service.signIn(workspaceURL: Self.host)
            await #expect(throws: DatabricksOAuthError.workspaceAlreadyConnected) {
                try await service.signIn(workspaceURL: "https://other.example.com")
            }
            #expect(logins.withLock { $0 } == 1)
            #expect(try await service.currentConnection() == first)
            #expect(try await service.accessToken(connectionID: first.id) == "access")
            try await service.remove(connectionID: first.id)
            #expect(try await service.currentConnection() == nil)
            #expect(memory.state.withLock { $0.credentials.isEmpty })
            let second = try await service.signIn(workspaceURL: "https://other.example.com")
            #expect(second.id != first.id)
            #expect(try await service.currentConnection() == second)
            await #expect(throws: DahliaCloudError.noCredential) {
                try await service.accessToken(connectionID: first.id)
            }
            #expect(memory.state.withLock { $0.credentials.count } == 1)
        }

        private func credential() -> DatabricksOAuthCredential {
            .init(
                accessToken: "old-access",
                refreshToken: "old-refresh",
                expirationDate: .distantFuture,
                tokenEndpoint: URL(string: Self.host + "/oidc/v1/token")!
            )
        }

        private func makeSession(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, String)) -> URLSession {
            DatabricksURLProtocol.handler.withLock { $0 = handler }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DatabricksURLProtocol.self]
            return URLSession(configuration: config)
        }
    }

    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    }

    private func form(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return query(URL(string: "https://form.invalid/?" + String(decoding: data, as: UTF8.self))!)
    }

    private final class DatabricksURLProtocol: URLProtocol, @unchecked Sendable {
        // URLProtocol callbacks run on Foundation queues; only the injected handler is mutable.
        static let handler = Mutex<(@Sendable (URLRequest) throws -> (Int, String))?>(nil)
        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let handle = Self.handler.withLock { $0! }
                let (status, body) = try handle(request)
                client?.urlProtocol(
                    self,
                    didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                    cacheStoragePolicy: .notAllowed
                )
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }

        override func stopLoading() {}
    }

    actor DatabricksAuthorizationGate {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
#endif
