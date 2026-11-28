import Foundation
import Security
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct GoogleCalendarConfigurationTests {
        @Test
        func calendarAuthorizationUsesCalendarListAndEventScopesOnly() {
            #expect(GoogleOAuthScope.calendar == [
                "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
                "https://www.googleapis.com/auth/calendar.events.readonly",
            ])
        }

        @Test
        func clientIDIsReadFromEnvironment() {
            withTemporaryEnvironmentValue("GOOGLE_CLIENT_ID", value: "client-id-from-env") {
                #expect(GoogleCalendarConfiguration.clientID == "client-id-from-env")
            }
        }

        @Test
        func clientSecretIsReadFromEnvironment() {
            withTemporaryEnvironmentValue("GOOGLE_CLIENT_SECRET", value: "secret-from-env") {
                #expect(GoogleCalendarConfiguration.clientSecret == "secret-from-env")
            }
        }

        @Test
        func tokenRequestBodyIncludesClientSecretWhenConfigured() {
            let body = GoogleSignInAdapter.makeTokenRequestBody(
                clientID: "client-id",
                clientSecret: "client-secret",
                parameters: ["grant_type": "refresh_token"]
            )

            #expect(body["client_id"] == "client-id")
            #expect(body["client_secret"] == "client-secret")
            #expect(body["grant_type"] == "refresh_token")
        }

        @Test(arguments: [400, 429, 500], ["refresh_token", "authorization_code"])
        func onlyAnInvalidRefreshGrantRequiresReauthentication(statusCode: Int, grantType: String) {
            let data = Data(#"{"error":"invalid_grant","error_description":"Token expired or revoked"}"#.utf8)
            let error = GoogleSignInAdapter.tokenRequestError(statusCode: statusCode, data: data, grantType: grantType)
            if case .reauthenticationRequired = error {
                #expect(statusCode == 400 && grantType == "refresh_token")
            } else {
                #expect(statusCode != 400 || grantType != "refresh_token")
            }
            let temporary = GoogleSignInAdapter.tokenRequestError(
                statusCode: statusCode, data: Data(#"{"error":"temporarily_unavailable"}"#.utf8), grantType: grantType
            )
            guard case .authorizationFailed = temporary else {
                Issue.record("Transient OAuth failures must remain errors")
                return
            }
        }

        @Test
        func currentSignInKeyIsNotARetiredOne() {
            #expect(!GoogleAuthSessionKind.retiredKeychainKeys.contains(GoogleAuthSessionKind.keychainKey))
        }

        /// A new sign-in keeps Calendar and other held scopes but never carries the retired read-all Drive scope.
        @Test
        func signInDropsTheRetiredDriveScope() {
            let held = GoogleOAuthScope.calendar.union(GoogleOAuthScope.retiredDrive)
            let scopes = GoogleSignInAdapter.authorizationScopesForSignIn(requestedScopes: GoogleOAuthScope.drive, held: held)
            #expect(scopes == GoogleOAuthScope.base.union(GoogleOAuthScope.calendar).union(GoogleOAuthScope.drive))
            let calendarOnly = GoogleSignInAdapter.authorizationScopesForSignIn(requestedScopes: GoogleOAuthScope.calendar, held: held)
            #expect(calendarOnly.isDisjoint(with: GoogleOAuthScope.retiredDrive))
            let url = GoogleSignInAdapter.makeAuthorizationURL(
                clientID: "client", redirectURL: URL(string: "http://127.0.0.1:8020")!, codeChallenge: "challenge", state: "state", scopes: scopes
            )
            let requested = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value
            #expect(requested?.contains("drive.readonly") == false)
            #expect(requested?.contains("drive.file") == true)
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "include_granted_scopes" } == false)
        }

        @Test
        func authorizationRequestsOnlyCalendarScopesWithoutEarlierGrants() throws {
            let url = try GoogleSignInAdapter.makeAuthorizationURL(
                clientID: "client-id",
                redirectURL: #require(URL(string: "http://127.0.0.1:8080/callback")),
                codeChallenge: "challenge",
                state: "state",
                scopes: GoogleOAuthScope.authorizationScopes(for: GoogleOAuthScope.calendar)
            )
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

            #expect(!items.contains { $0.name == "include_granted_scopes" })
            let scopes = try #require(items.first { $0.name == "scope" }?.value)
            #expect(Set(scopes.split(separator: " ").map(String.init)) == GoogleOAuthScope.base.union(GoogleOAuthScope.calendar))
        }

        @Test(arguments: [nil, "", "https://www.googleapis.com/auth/calendar.events.readonly"] as [String?])
        func tokenPayloadPreservesActualPartialAndOmittedGrants(scope: String?) throws {
            var response: [String: Any] = ["access_token": "test", "expires_in": 3600]
            response["scope"] = scope
            let payload = try JSONDecoder().decode(GoogleTokenPayload.self, from: JSONSerialization.data(withJSONObject: response))
            #expect(payload.grantedScopes == scope.map { $0.isEmpty ? [] : Set([$0]) })
            if let grants = payload.grantedScopes {
                let session = GoogleSession(
                    account: GoogleCalendarAccount(id: "test", displayName: "Test", email: ""),
                    accessToken: "test", grantedScopes: grants
                )
                #expect(!session.hasScopes(GoogleOAuthScope.drive))
            }
        }

        @Test
        func pendingDisconnectBlocksAutomaticSessionRestore() {
            #expect(GoogleSignInAdapter.shouldRestoreStoredSession(disconnectPending: true, hasStoredSession: true) == false)
            #expect(GoogleSignInAdapter.shouldRestoreStoredSession(disconnectPending: false, hasStoredSession: true))
            #expect(GoogleSignInAdapter.shouldRestoreStoredSession(disconnectPending: false, hasStoredSession: false) == false)
        }

        @Test
        func googleKeychainWorkerRunsOutsideTheMainThread() async {
            let worker = GoogleKeychainWorker()

            let runsOnMainThread = await worker.perform { Thread.isMainThread }

            #expect(!runsOnMainThread)
        }

        @Test
        func googleKeychainWorkerRejectsACommitFromBeforeDisconnect() async {
            let worker = GoogleKeychainWorker()
            let (_, generation) = await worker.snapshot(for: .calendar) {}
            await worker.beginDisconnect(for: .calendar)

            let committed = await worker.performIfCurrent(for: .calendar, generation: generation) {}

            #expect(!committed)
        }

        @Test
        func sharedGoogleSignInRejectsAnOlderRefresh() async {
            let worker = GoogleKeychainWorker()
            let (_, previous) = await worker.snapshot(for: .calendar) {}
            #expect(await worker.performIfCurrent(for: .calendar, generation: previous, replacingSession: true) {})
            #expect(await worker.performIfCurrent(for: .calendar, generation: previous) {} == false)
            let (_, current) = await worker.snapshot(for: .calendar) {}
            #expect(await worker.performIfCurrent(for: .calendar, generation: current) {})
            await worker.beginDisconnect(for: .calendar)
            #expect(await worker.performIfCurrent(for: .calendar, generation: current, replacingSession: true) {} == false)
        }

        @Test
        func googleKeychainWorkerRejectsCommitsStartedDuringDisconnect() async {
            let worker = GoogleKeychainWorker()
            await worker.beginDisconnect(for: .calendar)
            let (_, generation) = await worker.snapshot(for: .calendar) {}

            #expect(await worker.performIfCurrent(for: .calendar, generation: generation) {} == false)

            await worker.finishDisconnect(for: .calendar)
            #expect(await worker.performIfCurrent(for: .calendar, generation: generation) {} == false)
        }

        @Test
        func googleKeychainWorkerWaitsForAllOverlappingDisconnects() async {
            let worker = GoogleKeychainWorker()
            await worker.beginDisconnect(for: .calendar)
            await worker.beginDisconnect(for: .calendar)
            await worker.finishDisconnect(for: .calendar)
            let (_, generation) = await worker.snapshot(for: .calendar) {}

            #expect(await worker.performIfCurrent(for: .calendar, generation: generation) {} == false)

            await worker.finishDisconnect(for: .calendar)
            let (_, currentGeneration) = await worker.snapshot(for: .calendar) {}
            #expect(await worker.performIfCurrent(for: .calendar, generation: currentGeneration) {})
        }

        @Test
        func keychainDeletionAcceptsMissingItems() throws {
            try KeychainService.validateDeletionStatuses(
                protectedStatus: errSecItemNotFound,
                legacyStatus: errSecItemNotFound
            )
            try KeychainService.validateDeletionStatuses(
                protectedStatus: errSecMissingEntitlement,
                legacyStatus: errSecSuccess
            )
            try KeychainService.validateDeletionStatuses(
                protectedStatus: errSecInternalComponent,
                legacyStatus: errSecItemNotFound
            )
        }

        @Test
        func keychainDeletionRejectsUnexpectedFailures() {
            #expect(throws: KeychainService.KeychainError.self) {
                try KeychainService.validateDeletionStatuses(
                    protectedStatus: errSecAuthFailed,
                    legacyStatus: errSecItemNotFound
                )
            }
            #expect(throws: KeychainService.KeychainError.self) {
                try KeychainService.validateDeletionStatuses(
                    protectedStatus: errSecSuccess,
                    legacyStatus: errSecAuthFailed
                )
            }
        }

        @Test
        func loopbackRequestParserDistinguishesCallbacksFromUnrelatedRequests() throws {
            let callback = GoogleOAuthLoopbackRequestParser.parse(
                "GET /oauth2redirect?code=abc&state=expected HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            )
            let expectedURL = try #require(URL(string: "http://127.0.0.1/oauth2redirect?code=abc&state=expected"))

            #expect(callback == .callback(expectedURL))
            #expect(GoogleOAuthLoopbackRequestParser.parse("GET /favicon.ico HTTP/1.1\r\n\r\n") == .unrelated)
            #expect(GoogleOAuthLoopbackRequestParser.parse("POST /oauth2redirect HTTP/1.1\r\n\r\n") == .invalid)
        }

        @Test
        func callbackTimeoutHasAnActionableLocalizedMessage() {
            #expect(GoogleSignInError.authorizationTimedOut.errorDescription == L10n.googleAccountAuthorizationTimedOut)
        }

        @Test
        func authorizationCallbackRejectsWrongPathsAndDuplicateParameters() throws {
            let callback = try #require(URL(string: "http://127.0.0.1:54321/oauth2redirect?code=abc&state=expected"))
            let wrongPath = try #require(URL(string: "http://127.0.0.1:54321/favicon.ico?code=abc&state=expected"))
            let duplicateState = try #require(
                URL(string: "http://127.0.0.1:54321/oauth2redirect?code=abc&state=expected&state=other")
            )

            #expect(try GoogleSignInAdapter.extractAuthorizationCode(from: callback, expectedState: "expected") == "abc")
            #expect(throws: GoogleSignInError.self) {
                try GoogleSignInAdapter.extractAuthorizationCode(from: wrongPath, expectedState: "expected")
            }
            #expect(throws: GoogleSignInError.self) {
                try GoogleSignInAdapter.extractAuthorizationCode(from: duplicateState, expectedState: "expected")
            }
        }
    }

#endif

private func withTemporaryEnvironmentValue(_ key: String, value: String, operation: () -> Void) {
    let original = ProcessInfo.processInfo.environment[key]
    setenv(key, value, 1)
    defer {
        if let original {
            setenv(key, original, 1)
        } else {
            unsetenv(key)
        }
    }
    operation()
}
