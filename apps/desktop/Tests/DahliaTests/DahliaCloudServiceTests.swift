#if canImport(Testing)
    import Foundation
    import Network
    import Testing
    @testable import Dahlia

    @Suite(.serialized)
    struct DahliaCloudServiceTests {
        @Test
        func invalidConfigurationIsDisabled() {
            let values: [(String?, String?)] = [
                (nil, "client"),
                ("", "client"),
                ("not a URL", "client"),
                ("http://example.com", "client"),
                ("https://example.com/path", "client"),
                ("https://example.com", nil),
                ("https://example.com", "  "),
            ]
            for (url, clientID) in values {
                #expect(DahliaCloudConfiguration.make(urlString: url, clientID: clientID) == nil)
            }
        }

        @Test
        func validConfigurationNormalizesRootURL() throws {
            let configuration = try #require(DahliaCloudConfiguration.make(
                urlString: " https://cloud.example.com/ ",
                clientID: " desktop-client "
            ))

            #expect(configuration.baseURL.absoluteString == "https://cloud.example.com")
            #expect(configuration.clientID == "desktop-client")
            #expect(DahliaCloudConfiguration.defaultClientID == "databricks-cli")
            #expect(DahliaCloudConfiguration.make(
                urlString: "https://Cloud.Example.com:443/",
                clientID: "client"
            )?.origin == "https://cloud.example.com")
        }

        @Test
        func originComparisonNormalizesDefaultPorts() {
            #expect(DahliaCloudService.sameOrigin(
                "https://server.example.com/api/v1",
                "https://server.example.com:443"
            ))
            #expect(DahliaCloudService.sameOrigin(
                "http://localhost/api/v1",
                "http://localhost:80"
            ))
            #expect(!DahliaCloudService.sameOrigin(
                "https://server.example.com:8443/api/v1",
                "https://server.example.com"
            ))
        }

        @Test
        func authorizationRequestUsesFixedCallbackPKCEStateAndResource() throws {
            let configuration = try #require(DahliaCloudConfiguration.make(
                urlString: "https://cloud.example.com",
                clientID: "desktop-client"
            ))
            let url = try DahliaCloudService.authorizationURL(
                endpoint: URL(string: "https://accounts.example.com/authorize")!,
                configuration: configuration,
                resource: "https://cloud.example.com/api/v1",
                scopes: ["openid", "offline_access"],
                state: "state-value",
                codeChallenge: "challenge-value"
            )
            let values = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value) })

            #expect(values["client_id"] == "desktop-client")
            #expect(values["redirect_uri"] == "http://localhost:8020")
            #expect(values["resource"] == "https://cloud.example.com/api/v1")
            #expect(values["code_challenge_method"] == "S256")
            #expect(values["code_challenge"] == "challenge-value")
            #expect(values["state"] == "state-value")
        }

        @Test
        func callbackRejectsStateMismatchAndOAuthErrorsWithoutLeakingDetails() throws {
            let mismatch = URL(string: "http://127.0.0.1:8020/?code=secret-code&state=wrong")!
            #expect(throws: DahliaCloudError.stateMismatch) {
                try DahliaCloudService.authorizationCode(from: mismatch, expectedState: "right")
            }

            let denied = URL(string: "http://127.0.0.1:8020/?error=access_denied&error_description=secret&state=right")!
            do {
                _ = try DahliaCloudService.authorizationCode(from: denied, expectedState: "right")
                Issue.record("Expected authorization failure")
            } catch {
                #expect(error as? DahliaCloudError == .authorizationDenied)
                #expect(!error.localizedDescription.contains("secret"))
                #expect(!error.localizedDescription.contains("access_denied"))
            }

            let forgedDenial = URL(string: "http://127.0.0.1:8020/?error=access_denied&state=wrong")!
            #expect(throws: DahliaCloudError.stateMismatch) {
                try DahliaCloudService.authorizationCode(from: forgedDenial, expectedState: "right")
            }
        }

        @Test
        func callbackAcceptsURLNormalizedByLoopbackServer() throws {
            let request = "GET /?code=authorization-code&state=right HTTP/1.1\r\nHost: localhost:8020\r\n\r\n"
            guard case let .callback(callback) = OAuthLoopbackRequestParser.parse(request, callbackPath: "/") else {
                Issue.record("Expected callback request")
                return
            }

            #expect(callback.port == nil)
            #expect(try DahliaCloudService.authorizationCode(from: callback, expectedState: "right") == "authorization-code")
        }

        @Test
        func invalidOAuthResponsesIdentifyTheSafeFailureStage() {
            #expect(DahliaCloudError.invalidTokenResponse.localizedDescription.contains("token"))
            #expect(DahliaCloudError.invalidIdentityResponse.localizedDescription.contains("session"))
        }

        @Test
        func fixedCallbackPortConflictFailsBeforeBrowserAuthorization() async throws {
            let port = try #require(NWEndpoint.Port(rawValue: 8020))
            let first = try? await OAuthLoopbackRedirectServer(port: port, callbackPath: "/")

            await #expect(throws: (any Error).self) {
                _ = try await OAuthLoopbackRedirectServer(port: port, callbackPath: "/")
            }
            _ = first
        }

        @Test
        func signInUsesUserInfoWhenAdvertised() async throws {
            let recorder = CloudRequestRecorder(mode: .userInfo)
            let store = CloudCredentialStoreFake()
            let service = makeService(
                recorder: recorder,
                store: store,
                clientID: DahliaCloudConfiguration.defaultClientID
            )

            let credential = try await service.signIn()

            #expect(credential.account == DahliaCloudAccount(id: "user-1", name: "User One", email: "user@example.com"))
            let requests = recorder.requests
            #expect(requests.contains { $0.url?.path == "/userinfo" })
            #expect(!requests.contains { $0.url?.path == "/api/session" })
            let authorizationURL = try #require(recorder.authorizationURL)
            #expect(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "client_id" })?.value == "databricks-cli")
            let scope = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "scope" })?.value ?? ""
            #expect(scope.contains("openid"))
            #expect(scope.contains("offline_access"))
            #expect(!scope.contains("all-apis"))
        }

        @Test
        func databricksSignInUsesProxySessionAndMetadataScopes() async throws {
            let recorder = CloudRequestRecorder(mode: .proxySession)
            let store = CloudCredentialStoreFake()
            let service = makeService(
                recorder: recorder,
                store: store,
                clientID: DahliaCloudConfiguration.defaultClientID
            )

            let credential = try await service.signIn()

            #expect(credential.account.id == "db-user")
            #expect(recorder.requests.contains { $0.url?.path == "/api/session" })
            let authorizationURL = try #require(recorder.authorizationURL)
            #expect(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "client_id" })?.value == "databricks-cli")
            let scope = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "scope" })?.value ?? ""
            #expect(scope.contains("iam.current-user:read"))
            #expect(scope.contains("ai-gateway"))
            #expect(scope.contains("files"))
            #expect(scope.contains("offline_access"))
            #expect(!scope.contains("openid"))
            #expect(!scope.contains("profile"))
            #expect(!scope.contains("email"))
            #expect(!scope.contains("all-apis"))
            let tokenBody = try #require(recorder.tokenRequestBody)
            let tokenScope = URLComponents(string: "?\(tokenBody)")?.queryItems?
                .first(where: { $0.name == "scope" })?.value ?? ""
            #expect(tokenScope == scope)
        }

        @Test
        func tokenResponseRejectsScopesOutsideTheRequest() async throws {
            let recorder = CloudRequestRecorder(mode: .userInfo, tokenScope: "openid all-apis")
            let service = makeService(recorder: recorder, store: CloudCredentialStoreFake())

            await #expect(throws: DahliaCloudError.invalidTokenResponse) {
                try await service.signIn()
            }
        }

        @Test
        func refreshRejectsEmptyAccessTokenWithoutReplacingCredential() async throws {
            let oldCredential = makeCredential(expirationDate: .distantPast)
            let store = CloudCredentialStoreFake(credential: oldCredential)
            let service = makeService(
                recorder: CloudRequestRecorder(mode: .refresh, tokenAccessToken: ""),
                store: store
            )

            await #expect(throws: DahliaCloudError.invalidTokenResponse) {
                try await service.validAccessToken()
            }
            #expect(store.credential == oldCredential)
            #expect(store.saveCount == 0)
        }

        @Test
        func loopbackPageDoesNotReportOAuthErrorsAsCompleted() throws {
            let success = try #require(URL(string: "http://127.0.0.1:8020/?code=code&state=state"))
            let failure = try #require(URL(string: "http://127.0.0.1:8020/?error=access_denied&state=state"))

            #expect(OAuthLoopbackRedirectServer.callbackResponseBody(for: success).contains("completed"))
            #expect(OAuthLoopbackRedirectServer.callbackResponseBody(for: failure).contains("failed"))
            #expect(!OAuthLoopbackRedirectServer.callbackResponseBody(for: failure).contains("access_denied"))
        }

        @Test
        func validTokenIsReusedAndExpiredTokenRefreshIsCoalescedAndRotated() async throws {
            let recorder = CloudRequestRecorder(mode: .refresh)
            let store = CloudCredentialStoreFake(credential: makeCredential(expirationDate: .distantPast))
            let service = makeService(recorder: recorder, store: store)

            async let first = service.validAccessToken()
            async let second = service.validAccessToken()
            let tokens = try await [first, second]

            #expect(tokens == ["new-access", "new-access"])
            #expect(recorder.tokenRequestCount == 1)
            #expect(store.credential?.refreshToken == "new-refresh")
            #expect(store.saveCount == 1)

            _ = try await service.validAccessToken()
            #expect(recorder.tokenRequestCount == 1)
        }

        @Test
        func failedCredentialSaveKeepsOldRotatingRefreshToken() async throws {
            let old = makeCredential(expirationDate: .distantPast)
            let recorder = CloudRequestRecorder(mode: .refresh)
            let store = CloudCredentialStoreFake(credential: old, saveError: DahliaCloudError.credentialStorageFailed)
            let service = makeService(recorder: recorder, store: store)

            await #expect(throws: DahliaCloudError.credentialStorageFailed) {
                try await service.validAccessToken()
            }
            #expect(store.credential == old)
            #expect(store.credential?.refreshToken == "old-refresh")
        }

        @Test
        func restartRestoresCredentialAndSignOutUsesRevocationWhenAdvertised() async throws {
            let recorder = CloudRequestRecorder(mode: .refresh)
            let store = CloudCredentialStoreFake(credential: makeCredential(
                expirationDate: .distantFuture,
                revocationEndpoint: URL(string: "https://accounts.example.com/revoke")
            ))
            let restored = makeService(recorder: recorder, store: store)

            #expect(try await restored.storedCredential()?.account.id == "saved-user")
            try await restored.signOut()
            #expect(store.credential == nil)
            #expect(recorder.requests.contains { $0.url?.path == "/revoke" })
        }

        @Test
        func revocationFailureStillDeletesLocalCredential() async throws {
            let recorder = CloudRequestRecorder(mode: .refresh, revocationStatusCode: 503)
            let store = CloudCredentialStoreFake(credential: makeCredential(
                expirationDate: .distantFuture,
                revocationEndpoint: URL(string: "https://accounts.example.com/revoke")
            ))
            let service = makeService(recorder: recorder, store: store)

            await #expect(throws: DahliaCloudError.tokenRequestFailed(503)) {
                try await service.signOut()
            }
            #expect(store.credential == nil)
        }

        @Test
        func issuedCredentialCanBeRevokedWithoutBeingPersisted() async throws {
            let recorder = CloudRequestRecorder(mode: .refresh)
            let store = CloudCredentialStoreFake()
            let service = makeService(recorder: recorder, store: store)
            let credential = makeCredential(
                expirationDate: .distantFuture,
                revocationEndpoint: URL(string: "https://accounts.example.com/revoke")
            )

            await service.revokeIfPossible(credential)

            #expect(store.credential == nil)
            let request = try #require(recorder.requests.first { $0.url?.path == "/revoke" })
            #expect(CloudRequestRecorder.bodyString(for: request)?.contains("token=old-refresh") == true)
        }

        @MainActor
        @Test
        func signInReauthenticatesExistingConnectionForTheSameOrigin() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let connection = DahliaAccountConnectionRecord(
                id: .v7(),
                origin: "https://cloud.example.com",
                clientID: "desktop-client",
                createdAt: .now
            )
            try await repository.insertDahliaAccountConnection(connection)
            let store = CloudCredentialStoreFake()
            let service = makeService(recorder: CloudRequestRecorder(mode: .userInfo), store: store)
            let configuration = try #require(DahliaCloudConfiguration.make(
                urlString: connection.origin,
                clientID: connection.clientID
            ))
            let controller = DahliaCloudAccountController(
                configuration: configuration,
                serviceFactory: { _, _ in service }
            )
            await controller.configure(appDatabase: manager)

            let signIn = try #require(controller.startSignIn(configuration: configuration))
            await signIn.value

            #expect(try await repository.fetchDahliaAccountConnections().map(\.id) == [connection.id])
            #expect(controller.connections.first?.account?.id == "user-1")
            #expect(controller.completedSignInConnection(matching: configuration)?.id == connection.id)
            #expect(controller.errorMessage == nil)
        }

        @MainActor
        @Test
        func cancellationDuringCredentialSaveRollsBackNewConnection() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let recorder = CloudRequestRecorder(mode: .userInfo, advertisesRevocationEndpoint: true)
            let cancellation = CloudCancellationTrigger()
            let store = CloudCredentialStoreFake(onSave: cancellation.fire)
            let service = makeService(recorder: recorder, store: store)
            let configuration = try #require(DahliaCloudConfiguration.make(
                urlString: "https://cloud.example.com",
                clientID: "desktop-client"
            ))
            let controller = DahliaCloudAccountController(
                configuration: configuration,
                serviceFactory: { _, _ in service }
            )
            await controller.configure(appDatabase: manager)

            let signIn = try #require(controller.startSignIn(configuration: configuration))
            cancellation.set { signIn.cancel() }
            await signIn.value

            #expect(store.credential == nil)
            #expect(try await repository.fetchDahliaAccountConnections().isEmpty)
            #expect(controller.connections.isEmpty)
            #expect(recorder.requests.contains { $0.url?.path == "/revoke" })
        }

        @MainActor
        @Test
        func cancelledReauthenticationDoesNotProduceASignedInConnection() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let connection = DahliaAccountConnectionRecord(
                id: .v7(),
                origin: "https://cloud.example.com",
                clientID: "desktop-client",
                createdAt: .now
            )
            try await repository.insertDahliaAccountConnection(connection)
            let cancellation = CloudCancellationTrigger()
            let store = CloudCredentialStoreFake(onSave: cancellation.fire)
            let service = makeService(recorder: CloudRequestRecorder(mode: .userInfo), store: store)
            let configuration = try #require(DahliaCloudConfiguration.make(
                urlString: connection.origin,
                clientID: connection.clientID
            ))
            let controller = DahliaCloudAccountController(
                configuration: configuration,
                serviceFactory: { _, _ in service }
            )
            await controller.configure(appDatabase: manager)

            let signIn = try #require(controller.startSignIn(configuration: configuration))
            cancellation.set { signIn.cancel() }
            await signIn.value

            #expect(controller.errorMessage == nil)
            #expect(controller.signedInConnection(matching: configuration) == nil)
        }

        @MainActor
        @Test
        func cancelledReauthenticationDoesNotReportTheExistingConnectionAsCompleted() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let connection = DahliaAccountConnectionRecord(
                id: .v7(),
                origin: "https://cloud.example.com",
                clientID: "desktop-client",
                createdAt: .now
            )
            try await repository.insertDahliaAccountConnection(connection)
            let cancellation = CloudCancellationTrigger()
            let store = CloudCredentialStoreFake(
                credential: makeCredential(expirationDate: .distantFuture),
                onSave: cancellation.fire
            )
            let service = makeService(recorder: CloudRequestRecorder(mode: .userInfo), store: store)
            let configuration = try #require(DahliaCloudConfiguration.make(
                urlString: connection.origin,
                clientID: connection.clientID
            ))
            let controller = DahliaCloudAccountController(
                configuration: configuration,
                serviceFactory: { _, _ in service }
            )
            await controller.configure(appDatabase: manager)

            let signIn = try #require(controller.startSignIn(configuration: configuration))
            cancellation.set { signIn.cancel() }
            await signIn.value

            #expect(controller.completedSignInConnection(matching: configuration) == nil)
        }

        @MainActor
        @Test
        func failedReauthenticationSaveDiscardsIssuedCredential() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let connection = DahliaAccountConnectionRecord(
                id: .v7(),
                origin: "https://cloud.example.com",
                clientID: "desktop-client",
                createdAt: .now
            )
            try await repository.insertDahliaAccountConnection(connection)
            let configuration = try #require(DahliaCloudConfiguration.make(
                urlString: connection.origin,
                clientID: connection.clientID
            ))
            let recorder = CloudRequestRecorder(mode: .userInfo, advertisesRevocationEndpoint: true)
            let store = CloudCredentialStoreFake(saveError: DahliaCloudError.credentialStorageFailed)
            let service = makeService(recorder: recorder, store: store)
            let controller = DahliaCloudAccountController(
                configuration: configuration,
                serviceFactory: { _, _ in service }
            )
            await controller.configure(appDatabase: manager)

            let signIn = try #require(controller.startReauthentication(connectionID: connection.id))
            await signIn.value

            #expect(store.credential == nil)
            #expect(controller.connections.map(\.id) == [connection.id])
            #expect(controller.errorMessage != nil)
            #expect(recorder.requests.contains { $0.url?.path == "/revoke" })
        }

        @MainActor
        @Test
        func failedRollbackPublishesRetainedConnection() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let configuration = try #require(DahliaCloudConfiguration.make(
                urlString: "https://cloud.example.com",
                clientID: "desktop-client"
            ))
            let recorder = CloudRequestRecorder(mode: .userInfo, advertisesRevocationEndpoint: true)
            let store = CloudCredentialStoreFake(
                saveError: DahliaCloudError.credentialStorageFailed,
                deleteError: DahliaCloudError.credentialStorageFailed
            )
            let service = makeService(recorder: recorder, store: store)
            let controller = DahliaCloudAccountController(
                configuration: configuration,
                serviceFactory: { _, _ in service }
            )
            await controller.configure(appDatabase: manager)

            let signIn = try #require(controller.startSignIn(configuration: configuration))
            await signIn.value

            let retained = try await repository.fetchDahliaAccountConnections()
            #expect(retained.count == 1)
            #expect(controller.connections.map(\.id) == retained.map(\.id))
            #expect(controller.errorMessage != nil)
            #expect(recorder.requests.contains { $0.url?.path == "/revoke" })
        }

        @Test
        func refreshCannotRestoreCredentialAfterSignOut() async throws {
            let tokenResponseGate = CloudTokenResponseGate()
            let recorder = CloudRequestRecorder(mode: .refresh, tokenResponseGate: tokenResponseGate)
            let store = CloudCredentialStoreFake(credential: makeCredential(expirationDate: .distantPast))
            let service = makeService(recorder: recorder, store: store)
            let refresh = Task { try await service.validAccessToken() }
            defer {
                tokenResponseGate.release()
                refresh.cancel()
            }

            let refreshStarted = await tokenResponseGate.waitUntilStarted()
            #expect(refreshStarted)
            guard refreshStarted else { return }

            try await service.signOut()
            tokenResponseGate.release()
            _ = await refresh.result

            #expect(store.credential == nil)
            #expect(store.saveCount == 0)
        }

        @Test
        func signOutRejectsRefreshWhileRevocationIsInFlight() async throws {
            let revocationResponseGate = CloudTokenResponseGate()
            let recorder = CloudRequestRecorder(mode: .refresh, revocationResponseGate: revocationResponseGate)
            let store = CloudCredentialStoreFake(credential: makeCredential(
                expirationDate: .distantPast,
                revocationEndpoint: URL(string: "https://accounts.example.com/revoke")
            ))
            let service = makeService(recorder: recorder, store: store)
            let signOut = Task { try await service.signOut() }
            defer {
                revocationResponseGate.release()
                signOut.cancel()
            }

            let revocationStarted = await revocationResponseGate.waitUntilStarted()
            #expect(revocationStarted)
            guard revocationStarted else { return }

            await #expect(throws: DahliaCloudError.noCredential) {
                try await service.validAccessToken()
            }
            #expect(recorder.tokenRequestCount == 0)

            revocationResponseGate.release()
            try await signOut.value
            #expect(store.credential == nil)
        }

        @Test
        func storedCredentialWithDifferentClientIDIsNotReused() async throws {
            let recorder = CloudRequestRecorder(mode: .refresh)
            let store = CloudCredentialStoreFake(credential: makeCredential(
                expirationDate: .distantFuture,
                clientID: "retired-client"
            ))
            let service = makeService(recorder: recorder, store: store)

            #expect(try await service.storedCredential() == nil)
            await #expect(throws: DahliaCloudError.noCredential) {
                try await service.validAccessToken()
            }
        }

        @Test
        func storedCredentialFromDifferentConfiguredOriginIsNotReused() async throws {
            let store = CloudCredentialStoreFake(credential: makeCredential(expirationDate: .distantFuture))
            let service = DahliaCloudService(
                configuration: try #require(DahliaCloudConfiguration.make(
                    urlString: "https://replacement.example.com",
                    clientID: "desktop-client"
                )),
                storage: store.storage
            )

            #expect(try await service.storedCredential() == nil)
            await #expect(throws: DahliaCloudError.noCredential) {
                try await service.validAccessToken()
            }
            #expect(store.credential != nil)
        }

        @Test
        func signOutWithoutRevocationDeletesOnlyLocalCredential() async throws {
            let recorder = CloudRequestRecorder(mode: .refresh)
            let store = CloudCredentialStoreFake(credential: makeCredential(expirationDate: .distantFuture))
            let service = makeService(recorder: recorder, store: store)

            try await service.signOut()

            #expect(store.credential == nil)
            #expect(recorder.requests.isEmpty)
        }

        private func makeService(
            recorder: CloudRequestRecorder,
            store: CloudCredentialStoreFake,
            clientID: String = "desktop-client",
            authorize: DahliaCloudService.AuthorizationHandler? = nil
        ) -> DahliaCloudService {
            CloudURLProtocol.recorder = recorder
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CloudURLProtocol.self]
            let authorizationHandler = authorize ?? { url in
                recorder.authorizationURL = url
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "state" })?.value ?? ""
                return URL(string: "http://127.0.0.1:8020/?code=authorization-code&state=\(state)")!
            }
            return DahliaCloudService(
                configuration: DahliaCloudConfiguration.make(
                    urlString: "https://cloud.example.com",
                    clientID: clientID
                )!,
                session: URLSession(configuration: configuration),
                storage: store.storage,
                authorize: authorizationHandler
            )
        }

        private func makeCredential(
            expirationDate: Date,
            revocationEndpoint: URL? = nil,
            clientID: String = "desktop-client"
        ) -> DahliaCloudCredential {
            DahliaCloudCredential(
                accessToken: "old-access",
                refreshToken: "old-refresh",
                expirationDate: expirationDate,
                resource: "https://cloud.example.com",
                issuer: "https://accounts.example.com",
                clientID: clientID,
                grantedScopes: ["openid"],
                tokenEndpoint: URL(string: "https://accounts.example.com/token")!,
                revocationEndpoint: revocationEndpoint,
                account: DahliaCloudAccount(id: "saved-user", name: "Saved User", email: "saved@example.com")
            )
        }
    }

    private final class CloudCredentialStoreFake: @unchecked Sendable {
        private let lock = NSLock()
        private var storedCredential: DahliaCloudCredential?
        private let saveError: Error?
        private let deleteError: Error?
        private let onSave: (@Sendable () -> Void)?
        private(set) var saveCount = 0

        init(
            credential: DahliaCloudCredential? = nil,
            saveError: Error? = nil,
            deleteError: Error? = nil,
            onSave: (@Sendable () -> Void)? = nil
        ) {
            storedCredential = credential
            self.saveError = saveError
            self.deleteError = deleteError
            self.onSave = onSave
        }

        var credential: DahliaCloudCredential? {
            lock.withLock { storedCredential }
        }

        var storage: DahliaCloudCredentialStorage {
            DahliaCloudCredentialStorage(
                load: { self.lock.withLock { self.storedCredential } },
                save: { value in
                    self.onSave?()
                    try self.lock.withLock {
                        if let saveError = self.saveError { throw saveError }
                        self.storedCredential = value
                        self.saveCount += 1
                    }
                },
                delete: {
                    try self.lock.withLock {
                        if let deleteError = self.deleteError { throw deleteError }
                        self.storedCredential = nil
                    }
                }
            )
        }
    }

    private final class CloudCancellationTrigger: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?

        func set(_ action: @escaping @Sendable () -> Void) {
            lock.withLock { self.action = action }
        }

        func fire() {
            let currentAction: (@Sendable () -> Void)? = lock.withLock { self.action }
            currentAction?()
        }
    }

    private final class CloudTokenResponseGate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var started = false

        func block() {
            lock.withLock { started = true }
            semaphore.wait()
        }

        func waitUntilStarted() async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while clock.now < deadline {
                if lock.withLock({ started }) { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return lock.withLock { started }
        }

        func release() {
            semaphore.signal()
        }
    }

    private final class CloudRequestRecorder: @unchecked Sendable {
        enum Mode { case userInfo, proxySession, refresh }

        let mode: Mode
        let tokenScope: String?
        let tokenAccessToken: String?
        let tokenStatusCode: Int
        let revocationStatusCode: Int
        let tokenResponseGate: CloudTokenResponseGate?
        let revocationResponseGate: CloudTokenResponseGate?
        let advertisesRevocationEndpoint: Bool
        private let lock = NSLock()
        private var recordedRequests: [URLRequest] = []
        private var recordedAuthorizationURL: URL?
        private var recordedTokenRequestCount = 0
        private var recordedTokenRequestBody: String?

        init(
            mode: Mode,
            tokenScope: String? = nil,
            tokenAccessToken: String? = nil,
            tokenStatusCode: Int = 200,
            revocationStatusCode: Int = 200,
            tokenResponseGate: CloudTokenResponseGate? = nil,
            revocationResponseGate: CloudTokenResponseGate? = nil,
            advertisesRevocationEndpoint: Bool = false
        ) {
            self.mode = mode
            self.tokenScope = tokenScope
            self.tokenAccessToken = tokenAccessToken
            self.tokenStatusCode = tokenStatusCode
            self.revocationStatusCode = revocationStatusCode
            self.tokenResponseGate = tokenResponseGate
            self.revocationResponseGate = revocationResponseGate
            self.advertisesRevocationEndpoint = advertisesRevocationEndpoint
        }

        var requests: [URLRequest] { lock.withLock { recordedRequests } }
        var tokenRequestCount: Int { lock.withLock { recordedTokenRequestCount } }
        var tokenRequestBody: String? { lock.withLock { recordedTokenRequestBody } }
        var authorizationURL: URL? {
            get { lock.withLock { recordedAuthorizationURL } }
            set { lock.withLock { recordedAuthorizationURL = newValue } }
        }

        func response(for request: URLRequest) -> (HTTPURLResponse, Data) {
            let requestBody = Self.bodyString(for: request)
            lock.withLock {
                recordedRequests.append(request)
                if request.url?.path == "/token" {
                    recordedTokenRequestCount += 1
                    recordedTokenRequestBody = requestBody
                }
            }
            if request.url?.path == "/token" {
                tokenResponseGate?.block()
            } else if request.url?.path == "/revoke" {
                revocationResponseGate?.block()
            }
            let body: String
            switch request.url?.path {
            case "/.well-known/oauth-protected-resource":
                let scopes = mode == .proxySession ? "[\"iam.current-user:read\",\"all-apis\"]" : "[]"
                body = """
                {"resource":"https://cloud.example.com","authorization_servers":["https://accounts.example.com"],"scopes_supported":\(scopes)}
                """
            case "/.well-known/oauth-authorization-server":
                let userInfo = mode == .userInfo ? ",\"userinfo_endpoint\":\"https://accounts.example.com/userinfo\"" : ""
                let revocation = advertisesRevocationEndpoint
                    ? ",\"revocation_endpoint\":\"https://accounts.example.com/revoke\""
                    : ""
                body = """
                {"issuer":"https://accounts.example.com","authorization_endpoint":"https://accounts.example.com/authorize","token_endpoint":"https://accounts.example.com/token","code_challenge_methods_supported":["S256"]\(userInfo)\(revocation)}
                """
            case "/token":
                let scope = tokenScope.map { ",\"scope\":\"\($0)\"" } ?? ""
                let accessToken = tokenAccessToken ?? (mode == .refresh ? "new-access" : "signed-access")
                body = mode == .refresh
                    ? "{\"access_token\":\"\(accessToken)\",\"refresh_token\":\"new-refresh\",\"token_type\":\"Bearer\",\"expires_in\":3600\(scope)}"
                    : "{\"access_token\":\"\(accessToken)\",\"refresh_token\":\"signed-refresh\",\"token_type\":\"Bearer\",\"expires_in\":3600\(scope)}"
            case "/userinfo":
                body = "{\"sub\":\"user-1\",\"name\":\"User One\",\"email\":\"user@example.com\"}"
            case "/api/session":
                body = "{\"user\":{\"id\":\"db-user\",\"name\":\"DB User\",\"email\":\"db@example.com\"}}"
            default:
                body = "{}"
            }
            let statusCode = switch request.url?.path {
            case "/token": tokenStatusCode
            case "/revoke": revocationStatusCode
            default: 200
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }

        static func bodyString(for request: URLRequest) -> String? {
            if let body = request.httpBody { return String(data: body, encoding: .utf8) }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return String(data: data, encoding: .utf8)
        }
    }

    private final class CloudURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var recorder: CloudRequestRecorder?

        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let recorder = Self.recorder else { fatalError("CloudURLProtocol recorder is not configured") }
            let (response, data) = recorder.response(for: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
#endif
