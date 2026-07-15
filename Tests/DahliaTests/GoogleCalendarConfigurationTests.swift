import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

@MainActor
struct GoogleCalendarConfigurationTests {
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
