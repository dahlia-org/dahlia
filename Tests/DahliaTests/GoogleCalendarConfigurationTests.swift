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
        withTemporaryGoogleOAuthOverrides {
            withTemporaryEnvironmentValue("GOOGLE_CLIENT_ID", value: "client-id-from-env") {
                #expect(GoogleCalendarConfiguration.clientID == "client-id-from-env")
            }
        }
    }

    @Test
    func clientIDOverrideIsPreferredOverEnvironment() {
        withTemporaryGoogleOAuthOverrides(clientID: "client-id-from-settings") {
            withTemporaryEnvironmentValue("GOOGLE_CLIENT_ID", value: "client-id-from-env") {
                #expect(GoogleCalendarConfiguration.clientID == "client-id-from-settings")
            }
        }
    }

    @Test
    func blankClientIDOverrideFallsBackToEnvironment() {
        withTemporaryGoogleOAuthOverrides(clientID: "   ") {
            withTemporaryEnvironmentValue("GOOGLE_CLIENT_ID", value: "client-id-from-env") {
                #expect(GoogleCalendarConfiguration.clientID == "client-id-from-env")
            }
        }
    }

    @Test
    func clientSecretIsReadFromEnvironment() {
        withTemporaryGoogleOAuthOverrides {
            withTemporaryEnvironmentValue("GOOGLE_CLIENT_SECRET", value: "secret-from-env") {
                #expect(GoogleCalendarConfiguration.clientSecret == "secret-from-env")
            }
        }
    }

    @Test
    func clientSecretOverrideIsPreferredOverEnvironment() {
        withTemporaryGoogleOAuthOverrides(clientSecret: "secret-from-settings") {
            withTemporaryEnvironmentValue("GOOGLE_CLIENT_SECRET", value: "secret-from-env") {
                #expect(GoogleCalendarConfiguration.clientSecret == "secret-from-settings")
            }
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

    @Test
    func googleAuthSessionKindsUseSeparateStorageAndNotifications() {
        #expect(GoogleAuthSessionKind.calendar.keychainKey == "googleCalendarOAuthSession")
        #expect(GoogleAuthSessionKind.drive.keychainKey == "googleDriveOAuthSession")
        #expect(GoogleAuthSessionKind.calendar.sessionDidChangeNotification == .googleCalendarSessionDidChange)
        #expect(GoogleAuthSessionKind.drive.sessionDidChangeNotification == .googleDriveSessionDidChange)
    }

    @Test
    func pendingDisconnectBlocksAutomaticSessionRestore() {
        #expect(GoogleSignInAdapter.shouldRestoreStoredSession(disconnectPending: true, hasStoredSession: true) == false)
        #expect(GoogleSignInAdapter.shouldRestoreStoredSession(disconnectPending: false, hasStoredSession: true))
        #expect(GoogleSignInAdapter.shouldRestoreStoredSession(disconnectPending: false, hasStoredSession: false) == false)
    }

    @Test
    func disconnectSuppressionIsScopedPerGoogleService() {
        let calendarKey = GoogleSignInAdapter.disconnectPendingUserDefaultsKey(for: .calendar)
        let driveKey = GoogleSignInAdapter.disconnectPendingUserDefaultsKey(for: .drive)

        #expect(calendarKey != driveKey)
        #expect(GoogleSignInAdapter.shouldRestoreStoredSession(disconnectPending: false, hasStoredSession: true))
        #expect(GoogleSignInAdapter.shouldRestoreStoredSession(disconnectPending: true, hasStoredSession: true) == false)
    }

    @Test
    func revocationRequiresASuccessfulHTTPResponse() throws {
        let url = try #require(URL(string: "https://oauth2.googleapis.com/revoke"))
        let success = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let failure = try #require(HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil))
        let serverFailure = try #require(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil))

        try GoogleSignInAdapter.validateRevocationResponse(success)
        try GoogleSignInAdapter.validateRevocationResponse(
            failure,
            data: Data(#"{"error":"invalid_token"}"#.utf8)
        )
        #expect(throws: GoogleSignInError.self) {
            try GoogleSignInAdapter.validateRevocationResponse(failure)
        }
        #expect(throws: GoogleSignInError.self) {
            try GoogleSignInAdapter.validateRevocationResponse(serverFailure)
        }
        #expect(throws: GoogleSignInError.self) {
            try GoogleSignInAdapter.validateRevocationResponse(URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }
    }

    @Test
    func revocationTokensAreDeduplicatedPerGoogleAccount() {
        let groups = GoogleSignInAdapter.groupRevocationTokens([
            (accountID: "account-b", token: "token-b"),
            (accountID: "account-a", token: "token-a2"),
            (accountID: "account-a", token: "token-a1"),
            (accountID: "account-a", token: "token-a1"),
        ])

        #expect(groups == [["token-a1", "token-a2"], ["token-b"]])
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

#elseif canImport(XCTest)
import XCTest

@MainActor
final class GoogleCalendarConfigurationTests: XCTestCase {
    func testClientIDIsReadFromEnvironment() {
        withTemporaryGoogleOAuthOverrides {
            withTemporaryEnvironmentValue("GOOGLE_CLIENT_ID", value: "client-id-from-env") {
                XCTAssertEqual(GoogleCalendarConfiguration.clientID, "client-id-from-env")
            }
        }
    }

    func testClientIDOverrideIsPreferredOverEnvironment() {
        withTemporaryGoogleOAuthOverrides(clientID: "client-id-from-settings") {
            withTemporaryEnvironmentValue("GOOGLE_CLIENT_ID", value: "client-id-from-env") {
                XCTAssertEqual(GoogleCalendarConfiguration.clientID, "client-id-from-settings")
            }
        }
    }

    func testBlankClientIDOverrideFallsBackToEnvironment() {
        withTemporaryGoogleOAuthOverrides(clientID: "   ") {
            withTemporaryEnvironmentValue("GOOGLE_CLIENT_ID", value: "client-id-from-env") {
                XCTAssertEqual(GoogleCalendarConfiguration.clientID, "client-id-from-env")
            }
        }
    }

    func testClientSecretIsReadFromEnvironment() {
        withTemporaryGoogleOAuthOverrides {
            withTemporaryEnvironmentValue("GOOGLE_CLIENT_SECRET", value: "secret-from-env") {
                XCTAssertEqual(GoogleCalendarConfiguration.clientSecret, "secret-from-env")
            }
        }
    }

    func testClientSecretOverrideIsPreferredOverEnvironment() {
        withTemporaryGoogleOAuthOverrides(clientSecret: "secret-from-settings") {
            withTemporaryEnvironmentValue("GOOGLE_CLIENT_SECRET", value: "secret-from-env") {
                XCTAssertEqual(GoogleCalendarConfiguration.clientSecret, "secret-from-settings")
            }
        }
    }

    func testTokenRequestBodyIncludesClientSecretWhenConfigured() {
        let body = GoogleSignInAdapter.makeTokenRequestBody(
            clientID: "client-id",
            clientSecret: "client-secret",
            parameters: ["grant_type": "refresh_token"]
        )

        XCTAssertEqual(body["client_id"], "client-id")
        XCTAssertEqual(body["client_secret"], "client-secret")
        XCTAssertEqual(body["grant_type"], "refresh_token")
    }

    func testGoogleAuthSessionKindsUseSeparateStorageAndNotifications() {
        XCTAssertEqual(GoogleAuthSessionKind.calendar.keychainKey, "googleCalendarOAuthSession")
        XCTAssertEqual(GoogleAuthSessionKind.drive.keychainKey, "googleDriveOAuthSession")
        XCTAssertEqual(GoogleAuthSessionKind.calendar.sessionDidChangeNotification, .googleCalendarSessionDidChange)
        XCTAssertEqual(GoogleAuthSessionKind.drive.sessionDidChangeNotification, .googleDriveSessionDidChange)
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

private func withTemporaryGoogleOAuthOverrides(
    clientID: String? = nil,
    clientSecret: String? = nil,
    operation: () -> Void
) {
    withTemporaryUserDefaultsValue(AppSettings.googleOAuthClientIDOverrideUserDefaultsKey, value: clientID) {
        withTemporaryKeychainValue(AppSettings.googleOAuthClientSecretOverrideKey, value: clientSecret) {
            operation()
        }
    }
}

private func withTemporaryUserDefaultsValue(_ key: String, value: String?, operation: () -> Void) {
    let original = UserDefaults.standard.object(forKey: key)
    if let value {
        UserDefaults.standard.set(value, forKey: key)
    } else {
        UserDefaults.standard.removeObject(forKey: key)
    }
    defer {
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    operation()
}

private func withTemporaryKeychainValue(_ key: String, value: String?, operation: () -> Void) {
    let original = KeychainService.load(key: key)
    setTemporaryKeychainValue(key: key, value: value)
    defer {
        setTemporaryKeychainValue(key: key, value: original)
    }
    operation()
}

private func setTemporaryKeychainValue(key: String, value: String?) {
    if let value {
        try? KeychainService.save(key: key, value: value)
    } else {
        KeychainService.delete(key: key)
    }
}
