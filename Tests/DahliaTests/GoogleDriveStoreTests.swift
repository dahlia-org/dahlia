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
        private(set) var restoreCallCount = 0
        private(set) var signInRequestedScopes: [Set<String>] = []

        init(
            isConfigured: Bool = true,
            hasPreviousSignIn: Bool = false,
            sessionDidChangeNotification: Notification.Name = .googleDriveSessionDidChange,
            restoreResult: Result<GoogleSession, Error> = .success(driveSession),
            signInResult: Result<GoogleSession, Error> = .success(driveSession),
            refreshResult: Result<GoogleSession?, Error> = .success(driveSession)
        ) {
            self.isConfigured = isConfigured
            self.hasPreviousSignIn = hasPreviousSignIn
            self.sessionDidChangeNotification = sessionDidChangeNotification
            self.restoreResult = restoreResult
            self.signInResult = signInResult
            self.refreshResult = refreshResult
        }

        func restorePreviousSignIn() async throws -> GoogleSession {
            restoreCallCount += 1
            return try restoreResult.get()
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

        func configure(folderName _: String, session _: GoogleSession) async throws {
            try result.get()
        }

        func configureIfNeeded(session _: GoogleSession) async throws {
            configureIfNeededCallCount += 1
            try result.get()
        }
    }

#endif
