import AppKit
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct GoogleProviderAccountControllerTests {
        @Test
        func addingGoogleOnlyRequestsIdentityAndKeepsTheSelectedCalendarProvider() async throws {
            let suite = "GoogleProvider.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let selected = UUID().uuidString
            defaults.set(selected, forKey: GoogleCalendarProvider.userDefaultsKey)
            let signIn = ProviderGoogleSignIn()
            let controller = GoogleProviderAccountController(signInProvider: signIn, defaults: defaults)
            _ = NSApplication.shared
            let window = NSWindow()
            #expect(await controller.signIn(window: window))
            #expect(signIn.requestedScopes?.isEmpty == true)
            #expect(controller.hasConnection)
            #expect(controller.account?.id == "google-user")
            #expect(defaults.string(forKey: GoogleCalendarProvider.userDefaultsKey) == selected)
            controller.rename("Personal")
            #expect(controller.displayName == "Personal")
            let restored = GoogleProviderAccountController(signInProvider: signIn, defaults: defaults)
            await restored.activate()
            #expect(restored.displayName == "Personal")
            restored.rename(" ")
            #expect(restored.displayName.contains("me@example.com"))
            await controller.disconnect()
            #expect(signIn.disconnectCount == 1)
            #expect(!controller.hasConnection)
            #expect(controller.account == nil)
            #expect(defaults.string(forKey: GoogleCalendarProvider.userDefaultsKey) == selected)
        }

        @Test
        func aLateRestoreCannotUndoExternalGoogleSignOut() async throws {
            let signIn = ProviderGoogleSignIn()
            signIn.hasPreviousSignIn = true
            signIn.delaysRestore = true
            let controller = GoogleProviderAccountController(signInProvider: signIn)
            let task = Task { await controller.activate() }
            #expect(await pollUntil { signIn.restoreContinuation != nil })
            signIn.hasPreviousSignIn = false
            NotificationCenter.default.post(name: signIn.sessionDidChangeNotification, object: GoogleAuthSessionChangeReason.disconnected)
            #expect(await pollUntil { !controller.hasConnection })
            let continuation = try #require(signIn.restoreContinuation)
            continuation.resume(returning: signIn.session)
            await task.value
            #expect(controller.account == nil)
            #expect(!controller.hasConnection)
        }

        @Test
        func failedDisconnectKeepsTheProviderVisibleForRetry() async {
            let signIn = ProviderGoogleSignIn()
            signIn.hasPreviousSignIn = true
            let controller = GoogleProviderAccountController(signInProvider: signIn)
            await controller.activate()
            signIn.disconnectFails = true
            await controller.disconnect()
            #expect(controller.hasConnection)
            #expect(controller.account != nil)
            #expect(controller.errorMessage != nil)
            signIn.disconnectFails = false
            await controller.disconnect()
            #expect(!controller.hasConnection)
            #expect(controller.errorMessage == nil)
        }
    }

    @MainActor
    private final class ProviderGoogleSignIn: GoogleSignInProviding {
        let isConfigured = true
        var hasPreviousSignIn = false
        let sessionDidChangeNotification = Notification.Name("ProviderGoogleSignIn.\(UUID())")
        var requestedScopes: Set<String>?
        var disconnectCount = 0
        var disconnectFails = false
        var delaysRestore = false
        var restoreContinuation: CheckedContinuation<GoogleSession, any Error>?
        let session = GoogleSession(
            account: GoogleCalendarAccount(id: "google-user", displayName: "Me", email: "me@example.com"),
            accessToken: "synthetic", grantedScopes: GoogleOAuthScope.base
        )
        func restorePreviousSignIn() async throws -> GoogleSession {
            if delaysRestore { return try await withCheckedThrowingContinuation { restoreContinuation = $0 } }
            return session
        }

        func signIn(withPresentingWindow _: NSWindow, requestedScopes: Set<String>) async throws -> GoogleSession {
            self.requestedScopes = requestedScopes
            hasPreviousSignIn = true
            return session
        }

        func refreshCurrentSession() async throws -> GoogleSession? { hasPreviousSignIn ? session : nil }
        func disconnect() async throws {
            disconnectCount += 1
            if disconnectFails { throw GoogleSignInError.invalidTokenResponse }
            hasPreviousSignIn = false
        }
    }
#endif
