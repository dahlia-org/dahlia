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

        @Test(arguments: [false, true])
        func failedDisconnectKeepsARetryAfterNotificationAndSettingsReopen(notificationBeforeError: Bool) async throws {
            let suite = "PendingGoogleDisconnect.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let signIn = ProviderGoogleSignIn(defaults: defaults)
            signIn.hasPreviousSignIn = true
            let controller = GoogleProviderAccountController(signInProvider: signIn, defaults: defaults)
            await controller.activate()
            signIn.disconnectFails = true
            signIn.suspendsDisconnect = notificationBeforeError
            let disconnect = Task { await controller.disconnect() }
            if notificationBeforeError {
                #expect(await pollUntil { signIn.disconnectContinuation != nil && controller.account == nil })
                let continuation = try #require(signIn.disconnectContinuation)
                continuation.resume()
            }
            await disconnect.value
            // Account clearing proves the asynchronous notification ran, whether before or after the error.
            #expect(await pollUntil { controller.account == nil })
            #expect(controller.hasConnection)
            #expect(controller.isDisconnectPending)
            #expect(controller.errorMessage != nil)
            #expect(!signIn.hasPreviousSignIn)

            let reopenedSignIn = ProviderGoogleSignIn(defaults: defaults)
            let reopened = GoogleProviderAccountController(signInProvider: reopenedSignIn, defaults: defaults)
            await reopened.activate()
            #expect(reopened.hasConnection)
            #expect(reopened.isDisconnectPending)
            #expect(reopened.account == nil)
            await reopened.disconnect()
            #expect(reopenedSignIn.disconnectCount == 1)
            #expect(!reopenedSignIn.isDisconnectPending)
            #expect(!reopened.hasConnection)
            #expect(!reopened.isDisconnectPending)
            #expect(reopened.errorMessage == nil)
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
        var suspendsDisconnect = false
        var disconnectContinuation: CheckedContinuation<Void, Never>?
        private let defaults: UserDefaults?
        private var pendingDisconnect = false
        var isDisconnectPending: Bool {
            get { defaults?.bool(forKey: "pendingDisconnect") ?? pendingDisconnect }
            set {
                if let defaults {
                    defaults.set(newValue, forKey: "pendingDisconnect")
                } else {
                    pendingDisconnect = newValue
                }
            }
        }

        init(defaults: UserDefaults? = nil) { self.defaults = defaults }
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
            hasPreviousSignIn = false
            isDisconnectPending = disconnectFails
            NotificationCenter.default.post(name: sessionDidChangeNotification, object: GoogleAuthSessionChangeReason.disconnected)
            if suspendsDisconnect { await withCheckedContinuation { disconnectContinuation = $0 } }
            if disconnectFails { throw GoogleSignInError.invalidTokenResponse }
        }
    }
#endif
