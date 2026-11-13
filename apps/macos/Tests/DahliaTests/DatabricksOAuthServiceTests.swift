#if canImport(Testing)
    import CryptoKit
    import Foundation
    import Synchronization
    import Testing
    @testable import Dahlia

    final class DatabricksTestStorage: Sendable {
        struct State {
            var connections: [DatabricksConnection] = []
            /// The oldest connection, for tests of a single workspace.
            var connection: DatabricksConnection? {
                get { connections.first }
                set { connections = newValue.map { [$0] } ?? [] }
            }
            var credentials: [UUID: DatabricksOAuthCredential] = [:]
            var failSave = false
        }

        let state: Mutex<State>
        init(connection: DatabricksConnection? = nil) { state = Mutex(State(connections: connection.map { [$0] } ?? [])) }
        var storage: DatabricksOAuthStorage {
            DatabricksOAuthStorage(
                loadConnections: { self.state.withLock { $0.connections } },
                saveConnections: { connections in self.state.withLock { $0.connections = connections } },
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
        /// A non-first port proves the token exchange reuses the redirect URI the browser step chose.
        static let redirectURI = "http://localhost:8022"
        static let token = #"{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","expires_in":3600}"#

        @Test
        func aWorkspaceLinkOrABareHostNormalizesToTheWorkspaceOrigin() throws {
            let service = DatabricksOAuthService(storage: DatabricksOAuthStorage(
                loadConnections: { [] }, saveConnections: { _ in }, loadCredential: { _ in nil }, saveCredential: { _, _ in },
                deleteCredential: { _ in }
            ))
            for input in [
                "https://dbc-a5d4177a-49dc.cloud.databricks.com/ml/ai-gateway?o=1965859176160743",
                " HTTPS://DBC-a5d4177a-49dc.cloud.databricks.com:443/#notebook ",
                "dbc-a5d4177a-49dc.cloud.databricks.com/",
            ] {
                #expect(try service.normalizedWorkspaceURL(input).absoluteString == "https://dbc-a5d4177a-49dc.cloud.databricks.com", "\(input)")
            }
            // Plain HTTP, credentials in the URL, and no host stay refused.
            for input in ["http://dbc.cloud.databricks.com", "https://me:secret@dbc.cloud.databricks.com", "https://", " "] {
                #expect(throws: CodexConfigurationError.invalidDatabricksWorkspaceURL, "\(input)") {
                    try service.normalizedWorkspaceURL(input)
                }
            }
        }

        @Test @MainActor func restoresSelectionAfterCancellationFollowingConnectionSave() async throws {
            let memory = DatabricksTestStorage()
            var storage = memory.storage
            let save = storage.saveConnections
            storage.saveConnections = { connections in
                try save(connections)
                withUnsafeCurrentTask { $0?.cancel() }
            }
            let session = makeSession { request in
                request.url!.path.contains(".well-known") ? (404, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: storage, authorize: browser { url in
                URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })
            let controller = DatabricksAccountController(service: service)
            let signIn = Task { await controller.signIn(workspaceURL: Self.host) }
            #expect(await signIn.value == nil)
            let saved = try #require(memory.state.withLock { $0.connection })
            #expect(try await service.connections() == [saved])
        }

        @Test(arguments: [false, true]) @MainActor
        func signInDistinguishesNewAccountsFromReauthentication(alreadyConnected: Bool) async throws {
            let existing = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: alreadyConnected ? existing : nil)
            let session = makeSession { request in
                request.url!.path.contains(".well-known") ? (404, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage, authorize: browser { url in
                URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })
            let controller = DatabricksAccountController(service: service)

            let id = try #require(await controller.signIn(workspaceURL: Self.host))

            #expect(controller.isNewAccount == !alreadyConnected)
            if alreadyConnected { #expect(id == existing.id) }
            #expect(!controller.isBusy)
            #expect(controller.errorMessage == nil)
            #expect(try await service.connections().count == 1)

            // A failed later attempt must not retain the new-account state.
            #expect(await controller.signIn(workspaceURL: "http://example.com") == nil)
            #expect(!controller.isNewAccount)
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
                #expect(values["redirect_uri"] == Self.redirectURI)
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
            let service = DatabricksOAuthService(session: session, storage: memory.storage, authorize: browser { url in
                let values = query(url)
                #expect(url.path == (discovery ? "/custom/authorize" : "/oidc/v1/authorize"))
                #expect(values["scope"] == "offline_access all-apis")
                #expect(values["code_challenge_method"] == "S256")
                #expect(values["response_type"] == "code")
                #expect(values["redirect_uri"] == Self.redirectURI)
                challenge.withLock { $0 = values["code_challenge"]! }
                return URL(string: "http://127.0.0.1/?code=code&state=\(values["state"]!)")!
            })
            let connection = try await service.signIn(workspaceURL: Self.host)
            #expect(try await service.accessToken(connectionID: connection.id) == "access")
            #expect(requestCount.withLock { $0 } == 2)
            #expect(memory.state.withLock { $0.credentials[connection.id]?.refreshToken } == "refresh")
        }

        @Test func rejectsMismatchedStateBeforeTokenExchange() async throws {
            let session = makeSession { _ in (404, "") }
            defer { session.invalidateAndCancel() }
            let memory = DatabricksTestStorage()
            let service = DatabricksOAuthService(session: session, storage: memory.storage, authorize: browser { _ in
                URL(string: "http://127.0.0.1/?code=code&state=wrong")!
            })
            await #expect(throws: DahliaCloudError.stateMismatch) {
                try await service.signIn(workspaceURL: Self.host)
            }
            #expect(try await service.currentConnection() == nil)
        }

        @Test func connectionsAreDatabricksAccountsInTheDatabase() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let storage = DatabricksOAuthStorage.local(profile: .development) { database.dbQueue }
            // Both rows can get the same millisecond createdAt, so the IDs must already sort in insertion order.
            let ids = [UUID.v7(), UUID.v7()].sorted { $0.uuidString < $1.uuidString }
            let first = DatabricksConnection(id: ids[0], host: Self.host)
            var second = DatabricksConnection(id: ids[1], host: "https://other.example.com")

            try storage.saveConnections([first, second])
            #expect(try storage.loadConnections() == [first, second])
            second.email = "me@example.com"
            try storage.saveConnections([first, second])
            #expect(try storage.loadConnections().last?.email == "me@example.com")
            try storage.saveConnections([second])
            #expect(try storage.loadConnections() == [second])
            // The service and the Calendar proxy each hold a storage of the same database; neither reads a stale list.
            let other = DatabricksOAuthStorage.local(profile: .development) { database.dbQueue }
            second.email = "other@example.com"
            try other.saveConnections([second])
            #expect(try storage.loadConnections() == [second])
            try database.dbQueue.read { db throws in
                #expect(try DahliaAccountConnectionRecord.databricksWorkspaces.fetchAll(db).map(\.clientID) == ["databricks-cli"])
                #expect(try DahliaAccountConnectionRecord.dahliaServers.fetchCount(db) == 0)
            }
        }

        @Test func releasedSingleConnectionIsRemovedInsteadOfCarriedOver() throws {
            let suiteName = "DatabricksStorageTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let legacy = DatabricksConnection(id: UUID(), host: Self.host)
            try defaults.set(JSONEncoder().encode(legacy), forKey: "databricksOAuth.development.connection")
            var deleted: [String] = []

            DatabricksOAuthStorage.removeLegacyConnections(profile: .development, defaults: defaults) { deleted.append($0) }

            #expect(deleted == ["databricksOAuth.development.\(legacy.id.uuidString)"])
            #expect(defaults.data(forKey: "databricksOAuth.development.connection") == nil)
        }

        @Test func eachWorkspaceRefreshesItsOwnToken() async throws {
            let first = DatabricksConnection(id: UUID(), host: Self.host)
            let second = DatabricksConnection(id: UUID(), host: "https://other.example.com")
            let memory = DatabricksTestStorage()
            memory.state.withLock { state in
                state.connections = [first, second]
                for (connection, refresh) in [(first, "one"), (second, "two")] {
                    state.credentials[connection.id] = DatabricksOAuthCredential(
                        accessToken: "old", refreshToken: refresh, expirationDate: .distantPast,
                        tokenEndpoint: URL(string: connection.host + "/oidc/v1/token")!
                    )
                }
            }
            let session = makeSession { request in
                let refresh = form(request)["refresh_token"] ?? ""
                return (200, #"{"access_token":"access-\#(refresh)","token_type":"Bearer","expires_in":3600}"#)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage)

            async let one = service.accessToken(connectionID: first.id)
            async let two = service.accessToken(connectionID: second.id)
            #expect(try await [one, two] == ["access-one", "access-two"])
        }

        @Test func identityIsFetchedOnceAndSavedWithTheConnection() async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = credential() }
            let requests = Mutex(0)
            let session = makeSession { request in
                requests.withLock { $0 += 1 }
                #expect(request.url?.path == "/api/2.0/preview/scim/v2/Me")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access")
                return (200, #"{"userName":"me@example.com"}"#)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage)
            #expect(connection.accountLabel == "workspace")

            #expect(try await service.identifiedConnection(id: connection.id)?.accountLabel == "workspace (me@example.com)")
            #expect(try await service.identifiedConnection(id: connection.id)?.workspaceID == "1234")
            #expect(requests.withLock { $0 } == 1)
            #expect(memory.state.withLock { $0.connection?.email } == "me@example.com")
        }

        @Test func accessTokenStaysInMemoryAndOnlyARefreshReadsTheKeychain() async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = credential() }
            let loads = Mutex(0)
            var storage = memory.storage
            let load = storage.loadCredential
            storage.loadCredential = { id in
                loads.withLock { $0 += 1 }
                return try load(id)
            }
            let session = makeSession { request in
                #expect(form(request)["refresh_token"] == "old-refresh")
                return (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: storage)

            #expect(try await service.accessToken(connectionID: connection.id) == "old-access")
            #expect(try await service.accessToken(connectionID: connection.id) == "old-access")
            #expect(loads.withLock { $0 } == 1)
            // The refresh token comes from the Keychain; the refreshed access token replaces the cached one.
            #expect(try await service.accessToken(connectionID: connection.id, forceRefresh: true) == "access")
            #expect(loads.withLock { $0 } == 2)
            #expect(try await service.accessToken(connectionID: connection.id) == "access")
            #expect(loads.withLock { $0 } == 2)

            try await service.remove(connectionID: connection.id)
            await #expect(throws: DahliaCloudError.self) { try await service.accessToken(connectionID: connection.id) }
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
            let service = DatabricksOAuthService(session: session, storage: memory.storage, authorize: browser { url in
                logins.withLock { $0 += 1 }
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })
            #expect(try await service.accessToken(connectionID: connection.id, forceRefresh: true) == "access")
            #expect(logins.withLock { $0 } == 1)
        }

        @Test func nonInteractiveRefreshFailureThrowsWithoutLogin() async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = credential() }
            let logins = Mutex(0)
            let session = makeSession { request in
                form(request)["grant_type"] == "refresh_token" ? (400, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage, authorize: browser { url in
                logins.withLock { $0 += 1 }
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })
            await #expect(throws: Error.self) {
                try await service.accessToken(connectionID: connection.id, forceRefresh: true, interactive: false)
            }
            #expect(logins.withLock { $0 } == 0)
        }

        @Test func interactiveCallerJoiningFailedUnattendedRefreshStillLogsIn() async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = credential() }
            let (refreshStarted, startedContinuation) = AsyncStream.makeStream(of: Void.self)
            let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)
            let refreshes = Mutex(0)
            let logins = Mutex(0)
            let session = makeSession { request in
                if request.url!.path.contains(".well-known") { return (404, "") }
                guard form(request)["grant_type"] == "refresh_token" else { return (200, Self.token) }
                if refreshes.withLock({ $0 += 1; return $0 }) == 1 {
                    startedContinuation.yield()
                    for await _ in gate { break }
                }
                return (400, "")
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage, authorize: browser { url in
                logins.withLock { $0 += 1 }
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })

            let unattended = Task { try await service.accessToken(connectionID: connection.id, forceRefresh: true, interactive: false) }
            var started = refreshStarted.makeAsyncIterator()
            _ = await started.next()
            // The unattended refresh is suspended in its request, so this caller normally joins the pending operation,
            // which is the case that used to fail. Either ordering must end in exactly one interactive login.
            let interactive = Task { try await service.accessToken(connectionID: connection.id, forceRefresh: true) }
            gateContinuation.yield()

            await #expect(throws: Error.self) { try await unattended.value }
            #expect(try await interactive.value == "access")
            #expect(logins.withLock { $0 } == 1)
        }

        @Test func unattendedCallerDoesNotKeepCancelledInteractiveLoginAlive() async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = credential() }
            let (loginStarted, startedContinuation) = AsyncStream.makeStream(of: Void.self)
            let (gate, _) = AsyncStream.makeStream(of: Void.self)
            let logins = Mutex(0)
            let session = makeSession { request in
                request.url!.path.contains(".well-known") ? (404, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage, authorize: browser { url in
                logins.withLock { $0 += 1 }
                startedContinuation.yield()
                // Stays in the browser until cancelled; the gate is never opened.
                for await _ in gate {}
                try Task.checkCancellation()
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })

            let interactive = Task { try await service.accessToken(connectionID: connection.id, loginOnly: true) }
            var started = loginStarted.makeAsyncIterator()
            _ = await started.next()
            let unattended = Task { try await service.accessToken(connectionID: connection.id, interactive: false) }
            interactive.cancel()

            await #expect(throws: CancellationError.self) { try await interactive.value }
            // Whether it observed the cancelled login or arrived after it, the unattended caller finishes without a login.
            let result = await unattended.result
            if case let .success(token) = result { #expect(token == "old-access") }
            #expect(logins.withLock { $0 } == 1)
        }

        @Test func reauthenticatingExistingConnectionNotifiesObservers() async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = credential() }
            let session = makeSession { request in
                request.url!.path.contains(".well-known") ? (404, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage, authorize: browser { url in
                URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })
            let (posts, continuation) = AsyncStream.makeStream(of: Void.self)
            let token = NotificationCenter.default.addObserver(
                forName: .databricksConnectionDidChange, object: nil, queue: nil
            ) { _ in continuation.yield() }
            defer { NotificationCenter.default.removeObserver(token) }

            #expect(try await service.signIn(workspaceURL: Self.host) == connection)

            var iterator = posts.makeAsyncIterator()
            #expect(await iterator.next() != nil)
        }

        @Test func keychainFailureDoesNotPublishNewTokenOrStartLogin() async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = credential()
                $0.failSave = true
            }
            let session = makeSession { _ in (200, Self.token) }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage, authorize: browser { _ in
                Issue.record("Storage failures must not trigger a browser login")
                throw CancellationError()
            })
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
            storage.loadConnections = {
                continuation.yield(())
                return memory.state.withLock { $0.connections }
            }
            let gate = DatabricksAuthorizationGate()
            let logins = Mutex(0)
            let session = makeSession { request in
                request.url!.path.contains(".well-known") ? (404, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: storage, authorize: browser { url in
                logins.withLock { $0 += 1 }
                await gate.wait()
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })
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
            let service = DatabricksOAuthService(session: session, storage: memory.storage, authorize: browser { url in
                continuation.yield(())
                await gate.wait() // Deliberately finish even if the caller cancels.
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })
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
            let service = DatabricksOAuthService(session: session, storage: memory.storage, authorize: browser { url in
                URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })
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
            let service = DatabricksOAuthService(session: session, storage: memory.storage, authorize: browser { url in
                #expect(url.host == "workspace.example.com")
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })
            _ = try await service.signIn(workspaceURL: Self.host)
        }

        @Test(arguments: [false, true])
        func cancellingRefreshInitiatorPreservesRemainingWaiter(cancelAll: Bool) async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            memory.state.withLock { $0.credentials[connection.id] = credential() }
            let (reads, continuation) = AsyncStream<Void>.makeStream()
            let (requests, requestContinuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish()
                requestContinuation.finish()
            }
            var storage = memory.storage
            storage.loadConnections = {
                continuation.yield(())
                return memory.state.withLock { $0.connections }
            }
            let releaseRefresh = DatabricksAuthorizationGate()
            let refreshCount = Mutex(0)
            let session = makeSession { request in
                #expect(form(request)["grant_type"] == "refresh_token")
                refreshCount.withLock { $0 += 1 }
                requestContinuation.yield(())
                await releaseRefresh.wait()
                return (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: storage, authorize: browser { _ in
                Issue.record("Cancelling a waiter must not start browser authentication")
                throw CancellationError()
            })
            let original = Task { try await service.accessToken(connectionID: connection.id, forceRefresh: true) }
            var requestIterator = requests.makeAsyncIterator()
            _ = await requestIterator.next()
            var readIterator = reads.makeAsyncIterator()
            _ = await readIterator.next()
            let joined = Task { try await service.accessToken(connectionID: connection.id, forceRefresh: true) }
            _ = await readIterator.next()
            original.cancel()
            if cancelAll { joined.cancel() }
            await releaseRefresh.release()
            await #expect(throws: CancellationError.self) { try await original.value }
            if cancelAll {
                await #expect(throws: CancellationError.self) { try await joined.value }
                #expect(memory.state.withLock { $0.credentials[connection.id]?.accessToken } == "old-access")
            } else {
                #expect(try await joined.value == "access")
                #expect(memory.state.withLock { $0.credentials[connection.id]?.refreshToken } == "refresh")
            }
            #expect(refreshCount.withLock { $0 } == 1)
        }

        @Test func cancellingJoinedWaitLeavesOriginalLoginRunning() async throws {
            let connection = DatabricksConnection(id: UUID(), host: Self.host)
            let memory = DatabricksTestStorage(connection: connection)
            let (reads, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            var storage = memory.storage
            storage.loadConnections = {
                continuation.yield(())
                return memory.state.withLock { $0.connections }
            }
            let gate = DatabricksAuthorizationGate()
            let session = makeSession { request in
                request.url!.path.contains(".well-known") ? (404, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: storage, authorize: browser { url in
                await gate.wait()
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })
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
            storage.loadConnections = {
                continuation.yield(())
                return memory.state.withLock { $0.connections }
            }
            let releaseRefresh = DatabricksAuthorizationGate()
            let (requests, requestContinuation) = AsyncStream<Void>.makeStream()
            defer { requestContinuation.finish() }
            let logins = Mutex(0)
            let session = makeSession { request in
                if request.url!.path.contains(".well-known") { return (404, "") }
                if form(request)["grant_type"] == "refresh_token" {
                    requestContinuation.yield(())
                    // Suspend the response until the other caller joins without blocking Foundation queues.
                    await releaseRefresh.wait()
                }
                return (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: storage, authorize: browser { url in
                logins.withLock { $0 += 1 }
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })
            let refresh = Task { try await service.accessToken(connectionID: connection.id, forceRefresh: true) }
            var requestIterator = requests.makeAsyncIterator()
            _ = await requestIterator.next()
            var readIterator = reads.makeAsyncIterator()
            _ = await readIterator.next()
            let signIn = Task { try await service.signIn(workspaceURL: Self.host) }
            _ = await readIterator.next() // signIn's existing-connection lookup
            _ = await readIterator.next() // accessToken joins the pending refresh
            await releaseRefresh.release()
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

        @Test func workspacesAreAddedAndRemovedIndependently() async throws {
            let memory = DatabricksTestStorage()
            let logins = Mutex(0)
            let session = makeSession { request in
                request.url!.path.contains(".well-known") ? (404, "") : (200, Self.token)
            }
            defer { session.invalidateAndCancel() }
            let service = DatabricksOAuthService(session: session, storage: memory.storage, authorize: browser { url in
                logins.withLock { $0 += 1 }
                return URL(string: "http://127.0.0.1/?code=code&state=\(query(url)["state"]!)")!
            })
            let first = try await service.signIn(workspaceURL: Self.host)
            let second = try await service.signIn(workspaceURL: "https://other.example.com")
            #expect(logins.withLock { $0 } == 2)
            #expect(second.id != first.id)
            #expect(try await service.connections() == [first, second])
            // Signing in to a connected URL again refreshes it instead of adding a second connection.
            #expect(try await service.signIn(workspaceURL: Self.host) == first)
            #expect(try await service.connections().count == 2)
            #expect(try await service.accessToken(connectionID: first.id) == "access")
            try await service.remove(connectionID: first.id)
            #expect(try await service.connections() == [second])
            #expect(try await service.currentConnection() == second)
            await #expect(throws: DahliaCloudError.noCredential) {
                try await service.accessToken(connectionID: first.id)
            }
            #expect(memory.state.withLock { $0.credentials.count } == 1)
        }

        private func browser(
            _ callback: @escaping @Sendable (URL) async throws -> URL
        ) -> OAuthLoopbackAuthorization {
            { authorizationURL in try await (callback(authorizationURL(Self.redirectURI)), Self.redirectURI) }
        }

        private func credential() -> DatabricksOAuthCredential {
            .init(
                accessToken: "old-access",
                refreshToken: "old-refresh",
                expirationDate: .distantFuture,
                tokenEndpoint: URL(string: Self.host + "/oidc/v1/token")!
            )
        }

        private func makeSession(_ handler: @escaping @Sendable (URLRequest) async throws -> (Int, String)) -> URLSession {
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
        // Foundation callbacks and response tasks share only mutex-protected state.
        static let handler = Mutex<(@Sendable (URLRequest) async throws -> (Int, String))?>(nil)
        private let responseTask = Mutex<Task<Void, Never>?>(nil)
        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let handle = Self.handler.withLock { $0! }
            let task = Task { @Sendable [self] in
                do {
                    let (status, body) = try await handle(request)
                    try Task.checkCancellation()
                    client?.urlProtocol(
                        self,
                        didReceive: HTTPURLResponse(
                            url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["x-databricks-org-id": "1234"]
                        )!,
                        cacheStoragePolicy: .notAllowed
                    )
                    client?.urlProtocol(self, didLoad: Data(body.utf8))
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
                }
            }
            responseTask.withLock { $0 = task }
        }

        override func stopLoading() {
            let task = responseTask.withLock { task in
                defer { task = nil }
                return task
            }
            task?.cancel()
        }
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
