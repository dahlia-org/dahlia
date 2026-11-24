import AppKit
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct GoogleProviderAccountControllerTests {
        private func providerWorker() throws -> GoogleProviderAccountWorker {
            let database = try AppDatabaseManager(path: ":memory:")
            return GoogleProviderAccountWorker(storage: .local(database: { database.dbQueue }), pendingDisconnects: { [] })
        }

        @Test
        func addingGoogleRequestsCalendarAndDriveAndKeepsTheSelectedCalendarProvider() async throws {
            let suite = "GoogleProvider.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let selected = UUID().uuidString
            defaults.set(selected, forKey: GoogleCalendarProvider.userDefaultsKey)
            let worker = try providerWorker()
            let signIn = ProviderGoogleSignIn()
            let controller = GoogleProviderAccountController(signInProvider: signIn, worker: worker)
            _ = NSApplication.shared
            let window = NSWindow()
            #expect(await controller.signIn(window: window))
            #expect(signIn.requestedScopes == GoogleOAuthScope.calendar.union(GoogleOAuthScope.drive))
            #expect(controller.hasConnection)
            #expect(controller.account?.id == "google-user")
            #expect(defaults.string(forKey: GoogleCalendarProvider.userDefaultsKey) == selected)
            await controller.rename("Personal")
            #expect(controller.displayName == "Personal")
            let restored = GoogleProviderAccountController(id: controller.id, signInProvider: signIn, worker: worker)
            await restored.activate()
            #expect(restored.displayName == "Personal")
            await restored.rename(" ")
            #expect(restored.displayName.contains("me@example.com"))
            await controller.disconnect()
            #expect(signIn.disconnectCount == 1)
            #expect(!controller.hasConnection)
            #expect(controller.account == nil)
            #expect(defaults.string(forKey: GoogleCalendarProvider.userDefaultsKey) == selected)
        }

        @Test
        func addingTwoGoogleAccountsKeepsBothAndRemovingOnePreservesTheOther() async throws {
            let worker = try providerWorker()
            let firstSignIn = ProviderGoogleSignIn()
            let secondSignIn = ProviderGoogleSignIn()
            secondSignIn.session = GoogleSession(
                account: .init(id: "second-user", displayName: "Second", email: "second@example.com"),
                accessToken: "second-fixture", grantedScopes: GoogleOAuthScope.base
            )
            let first = GoogleProviderAccountController(signInProvider: firstSignIn, worker: worker)
            let second = GoogleProviderAccountController(signInProvider: secondSignIn, worker: worker)
            _ = NSApplication.shared
            let window = NSWindow()
            #expect(await first.signIn(window: window))
            #expect(await second.signIn(window: window))
            let model = GoogleProviderAccountsModel(worker: worker)
            await model.activate()
            #expect(await pollUntil { Set(model.accounts.map(\.id)) == [first.id, second.id] })
            await first.rename("Personal")
            #expect(await pollUntil { model.accounts.first { $0.id == first.id }?.name == "Personal" })
            await first.disconnect()
            #expect(await pollUntil { model.accounts.map(\.id) == [second.id] })
            #expect(secondSignIn.hasPreviousSignIn)
            #expect(secondSignIn.disconnectCount == 0)
            #expect(second.hasConnection)
        }

        @Test(arguments: [false, true])
        func failedFirstRegistrationRemainsDiscoverableForDeletion(metadataReadFails: Bool) async throws {
            let suite = "FailedGoogleRegistration.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let id = UUID.v7()
            let pendingKey = GoogleSignInAdapter.disconnectPendingUserDefaultsKey(for: .calendar.forAccount(id))
            let worker = GoogleProviderAccountWorker(
                storage: .init(
                    load: {
                        if metadataReadFails { throw GoogleSignInError.invalidTokenResponse }
                        return []
                    },
                    save: { _ in throw GoogleSignInError.invalidTokenResponse },
                    remove: { _ in Issue.record("Cleanup without a registration must not depend on SQLite") }
                ),
                pendingDisconnects: {
                    GoogleSignInAdapter.pendingDisconnectAccountIDs(defaults: UserDefaults(suiteName: suite)!)
                }
            )
            let signIn = ProviderGoogleSignIn(defaults: defaults, pendingKey: pendingKey)
            signIn.disconnectFails = true
            let controller = GoogleProviderAccountController(id: id, signInProvider: signIn, worker: worker)
            _ = NSApplication.shared
            #expect(await controller.signIn(window: NSWindow()) == false)
            #expect(controller.isDisconnectPending)
            #expect(defaults.bool(forKey: pendingKey))
            let recoveredSignIn = ProviderGoogleSignIn(defaults: defaults, pendingKey: pendingKey)
            let reopened = GoogleProviderAccountsModel(worker: worker, signInProvider: { _ in recoveredSignIn })
            await reopened.activate()
            #expect(reopened.accounts.isEmpty)
            #expect(await pollUntil { reopened.controllers.contains { $0.id == id } })
            let recovery = try #require(reopened.controllers.first { $0.id == id })
            #expect(recovery.isDisconnectPending)
            #expect(recovery.hasConnection)
            #expect(recoveredSignIn.disconnectCount == 0)
            await recovery.disconnect()
            #expect(recoveredSignIn.disconnectCount == 1)
            #expect(!defaults.bool(forKey: pendingKey))
            #expect(await pollUntil { reopened.controllers.isEmpty })
        }

        @Test
        func aLateRestoreCannotUndoExternalGoogleSignOut() async throws {
            let worker = try providerWorker()
            let signIn = ProviderGoogleSignIn()
            signIn.hasPreviousSignIn = true
            signIn.delaysRestore = true
            let controller = GoogleProviderAccountController(signInProvider: signIn, worker: worker)
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
            let worker = try providerWorker()
            let signIn = ProviderGoogleSignIn(defaults: defaults)
            signIn.hasPreviousSignIn = true
            let controller = GoogleProviderAccountController(signInProvider: signIn, worker: worker)
            _ = NSApplication.shared
            #expect(await controller.signIn(window: NSWindow()))
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
            let reopened = GoogleProviderAccountController(id: controller.id, signInProvider: reopenedSignIn, worker: worker)
            await reopened.activate()
            #expect(reopened.hasConnection)
            #expect(reopened.isDisconnectPending)
            #expect(reopened.account == nil)
            #expect(try await worker.load().map(\.id) == [controller.id])
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
        private let pendingKey: String
        private var pendingDisconnect = false
        var isDisconnectPending: Bool {
            get { defaults?.bool(forKey: pendingKey) ?? pendingDisconnect }
            set {
                if let defaults {
                    defaults.set(newValue, forKey: pendingKey)
                } else {
                    pendingDisconnect = newValue
                }
            }
        }

        init(defaults: UserDefaults? = nil, pendingKey: String = "pendingDisconnect") {
            self.defaults = defaults
            self.pendingKey = pendingKey
        }

        var delaysRestore = false
        var restoreContinuation: CheckedContinuation<GoogleSession, any Error>?
        var session = GoogleSession(
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
