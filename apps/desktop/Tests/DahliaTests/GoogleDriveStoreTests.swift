import AppKit
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct GoogleDriveStoreTests {
        @Test
        func driveAuthorizationUsesFileScopeOnly() {
            #expect(GoogleOAuthScope.drive == ["https://www.googleapis.com/auth/drive.file"])
        }

        @Test
        func restoreWithoutDriveScopeStaysSignedOut() async {
            let signInProvider = MockGoogleSignInProvider(
                hasPreviousSignIn: true,
                restoreResult: .success(calendarOnlySession)
            )
            let store = GoogleDriveStore(
                signInProvider: signInProvider,
                exportFolderConfiguration: MockGoogleDriveExportFolderConfiguration(),
                presentingWindowProvider: { NSWindow() }
            )

            await store.restoreSessionIfNeeded()

            #expect(store.state == .signedOut)
            #expect(!store.isAuthorized)
            #expect(store.account == calendarOnlySession.account)
        }

        @Test
        func restoreFailureCanBeRetried() async {
            let signInProvider = MockGoogleSignInProvider(
                hasPreviousSignIn: true,
                restoreResult: .failure(GoogleSignInError.authorizationFailed("Expired session"))
            )
            let store = GoogleDriveStore(
                signInProvider: signInProvider,
                exportFolderConfiguration: MockGoogleDriveExportFolderConfiguration()
            )

            await store.restoreSessionIfNeeded()
            signInProvider.restoreResult = .success(driveSession)
            await store.restoreSessionIfNeeded()

            #expect(signInProvider.restoreCallCount == 2)
            #expect(store.isAuthorized)
            #expect(store.lastErrorMessage == nil)
        }

        @Test
        func authorizedOperationReportsBusyUntilCompletion() async throws {
            let store = GoogleDriveStore(
                signInProvider: MockGoogleSignInProvider(),
                exportFolderConfiguration: MockGoogleDriveExportFolderConfiguration()
            )

            let wasBusy = try await store.performAuthorizedOperation { _ in
                await MainActor.run { store.isBusy }
            }

            #expect(wasBusy)
            #expect(!store.isBusy)
        }

        @Test
        func signInRequestsDriveScopes() async {
            let signInProvider = MockGoogleSignInProvider(
                signInResult: .success(driveSession)
            )
            let folderConfiguration = MockGoogleDriveExportFolderConfiguration()
            let store = GoogleDriveStore(
                signInProvider: signInProvider,
                exportFolderConfiguration: folderConfiguration,
                presentingWindowProvider: { NSWindow() }
            )

            await store.signIn()

            #expect(signInProvider.signInRequestedScopes == [GoogleOAuthScope.drive])
            #expect(folderConfiguration.configureIfNeededCallCount == 1)
        }

        @Test
        func disconnectClearsStoredExportFolderIdentifier() async {
            let settings = MockGoogleDriveExportFolderSettings()
            settings.setGoogleDriveExportFolder(id: "folder-1", accountID: driveSession.account.id)
            let store = GoogleDriveStore(
                signInProvider: MockGoogleSignInProvider(signInResult: .success(driveSession)),
                exportFolderConfiguration: MockGoogleDriveExportFolderConfiguration(),
                settings: settings,
                presentingWindowProvider: { NSWindow() }
            )

            await store.signIn()
            await store.disconnect()

            #expect(settings.googleDriveExportFolderID(forAccountID: driveSession.account.id) == nil)
        }

        @Test
        func folderConfigurationFailureKeepsAuthorizedSessionAndReportsError() async {
            let folderConfiguration = MockGoogleDriveExportFolderConfiguration(
                result: .failure(GoogleDriveAPIError.httpError(statusCode: 503, detail: "Unavailable"))
            )
            let store = GoogleDriveStore(
                signInProvider: MockGoogleSignInProvider(signInResult: .success(driveSession)),
                exportFolderConfiguration: folderConfiguration,
                presentingWindowProvider: { NSWindow() }
            )

            await store.signIn()

            #expect(store.isAuthorized)
            #expect(store.state == .connected)
            #expect(store.exportFolderErrorMessage != nil)
        }

        @Test
        func ignoresUnrelatedSessionChangeNotification() async {
            let watchedNotification = Notification.Name("GoogleDriveStoreTests.watched.\(UUID().uuidString)")
            let ignoredNotification = Notification.Name("GoogleDriveStoreTests.ignored.\(UUID().uuidString)")
            let signInProvider = MockGoogleSignInProvider(
                hasPreviousSignIn: true,
                sessionDidChangeNotification: watchedNotification,
                restoreResult: .success(driveSession)
            )
            let store = GoogleDriveStore(
                signInProvider: signInProvider,
                exportFolderConfiguration: MockGoogleDriveExportFolderConfiguration()
            )

            NotificationCenter.default.post(name: ignoredNotification, object: nil)
            await Task.yield()

            #expect(store.state == .signedOut)
            #expect(signInProvider.restoreCallCount == 0)
        }

        @Test
        func disconnectNotificationDoesNotRestoreResidualCredentials() async {
            let watchedNotification = Notification.Name("GoogleDriveStoreTests.disconnect.\(UUID().uuidString)")
            let signInProvider = MockGoogleSignInProvider(
                hasPreviousSignIn: true,
                sessionDidChangeNotification: watchedNotification,
                signInResult: .success(driveSession)
            )
            let settings = MockGoogleDriveExportFolderSettings()
            settings.setGoogleDriveExportFolder(id: "folder-1", accountID: driveSession.account.id)
            let store = GoogleDriveStore(
                signInProvider: signInProvider,
                exportFolderConfiguration: MockGoogleDriveExportFolderConfiguration(),
                settings: settings,
                presentingWindowProvider: { NSWindow() }
            )

            NotificationCenter.default.post(
                name: watchedNotification,
                object: GoogleAuthSessionChangeReason.disconnected
            )

            #expect(await pollUntil {
                store.state == .signedOut
                    && settings.googleDriveExportFolderID(forAccountID: driveSession.account.id) == nil
            })
            #expect(signInProvider.restoreCallCount == 0)
        }

        @Test
        func disconnectNotificationWaitsBehindInFlightRestore() async throws {
            let watchedNotification = Notification.Name("GoogleDriveStoreTests.restoreDisconnect.\(UUID().uuidString)")
            let settings = MockGoogleDriveExportFolderSettings()
            let signInProvider = MockGoogleSignInProvider(
                hasPreviousSignIn: true,
                sessionDidChangeNotification: watchedNotification,
                suspendsRestore: true
            )
            let store = GoogleDriveStore(
                signInProvider: signInProvider,
                exportFolderConfiguration: MockGoogleDriveExportFolderConfiguration(),
                settings: settings,
                presentingWindowProvider: { NSWindow() }
            )
            await store.signIn()
            settings.setGoogleDriveExportFolder(id: "folder-1", accountID: driveSession.account.id)

            NotificationCenter.default.post(name: watchedNotification, object: nil)
            try #require(await pollUntil { signInProvider.restoreCallCount == 1 })

            NotificationCenter.default.post(
                name: watchedNotification,
                object: GoogleAuthSessionChangeReason.disconnected
            )
            signInProvider.finishRestore()

            #expect(await pollUntil {
                store.state == .signedOut
                    && settings.googleDriveExportFolderID(forAccountID: driveSession.account.id) == nil
            })
        }
    }

    private let calendarOnlySession = GoogleSession(
        account: GoogleCalendarAccount(id: "user-1", displayName: "Kazuki", email: "kazuki@example.com"),
        accessToken: "calendar-token",
        grantedScopes: GoogleOAuthScope.authorizationScopes(for: GoogleOAuthScope.calendar)
    )

    private let driveSession = GoogleSession(
        account: GoogleCalendarAccount(id: "user-1", displayName: "Kazuki", email: "kazuki@example.com"),
        accessToken: "drive-token",
        grantedScopes: GoogleOAuthScope.authorizationScopes(for: GoogleOAuthScope.drive)
    )

    @MainActor
    private final class MockGoogleSignInProvider: GoogleSignInProviding {
        let isConfigured: Bool
        let hasPreviousSignIn: Bool
        let sessionDidChangeNotification: Notification.Name
        var restoreResult: Result<GoogleSession, Error>
        var signInResult: Result<GoogleSession, Error>
        var refreshResult: Result<GoogleSession?, Error>
        private let suspendsRestore: Bool
        private var restoreContinuation: CheckedContinuation<Void, Never>?
        private(set) var restoreCallCount = 0
        private(set) var signInRequestedScopes: [Set<String>] = []

        init(
            isConfigured: Bool = true,
            hasPreviousSignIn: Bool = false,
            sessionDidChangeNotification: Notification.Name = .googleDriveSessionDidChange,
            restoreResult: Result<GoogleSession, Error> = .success(driveSession),
            signInResult: Result<GoogleSession, Error> = .success(driveSession),
            refreshResult: Result<GoogleSession?, Error> = .success(driveSession),
            suspendsRestore: Bool = false
        ) {
            self.isConfigured = isConfigured
            self.hasPreviousSignIn = hasPreviousSignIn
            self.sessionDidChangeNotification = sessionDidChangeNotification
            self.restoreResult = restoreResult
            self.signInResult = signInResult
            self.refreshResult = refreshResult
            self.suspendsRestore = suspendsRestore
        }

        func restorePreviousSignIn() async throws -> GoogleSession {
            restoreCallCount += 1
            if suspendsRestore {
                await withCheckedContinuation { continuation in
                    restoreContinuation = continuation
                }
            }
            return try restoreResult.get()
        }

        func finishRestore() {
            restoreContinuation?.resume()
            restoreContinuation = nil
        }

        func signIn(withPresentingWindow _: NSWindow, requestedScopes: Set<String>) async throws -> GoogleSession {
            signInRequestedScopes.append(requestedScopes)
            return try signInResult.get()
        }

        func refreshCurrentSession() async throws -> GoogleSession? {
            try refreshResult.get()
        }

        func disconnect() async throws {}
    }

    @MainActor
    private final class MockGoogleDriveExportFolderConfiguration: GoogleDriveExportFolderConfiguring {
        private let result: Result<Void, Error>
        private(set) var configureIfNeededCallCount = 0

        init(result: Result<Void, Error> = .success(())) {
            self.result = result
        }

        func configureIfNeeded(session _: GoogleSession) async throws {
            configureIfNeededCallCount += 1
            try result.get()
        }
    }

    @MainActor
    private final class MockGoogleDriveExportFolderSettings: GoogleDriveExportFolderSettingsProviding {
        private var folderIDs: [String: String] = [:]

        func googleDriveExportFolderID(forAccountID accountID: String, scope _: AppAccountScope) -> String? {
            folderIDs[accountID]
        }

        func setGoogleDriveExportFolder(id: String, accountID: String, scope _: AppAccountScope) {
            folderIDs[accountID] = id
        }

        func clearGoogleDriveExportFolderID(forAccountID accountID: String, scope _: AppAccountScope) {
            folderIDs.removeValue(forKey: accountID)
        }

        func clearGoogleDriveExportFolder(scope _: AppAccountScope) {
            folderIDs.removeAll()
        }
    }

#endif
