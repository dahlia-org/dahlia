import AppKit
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct GoogleDriveBackupModelTests {
        @Test
        func refreshAndDisconnectClearTheCloudListWithoutDeletingFiles() async {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DriveBackupURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let signIn = BackupReadSignIn()
            let model = GoogleDriveBackupModel(signIn: signIn, client: GoogleDriveBackupClient(urlSession: transport))
            await model.refresh()
            #expect(model.isAuthorized)
            #expect(model.files.count == 2)
            await model.disconnect()
            #expect(!model.isAuthorized)
            #expect(!model.hasConnection)
            #expect(model.files.isEmpty)
            #expect(signIn.disconnectCount == 1)
        }

        @Test(arguments: [false, true])
        func externalSessionAndRouteChangesRejectAnOlderRestore(routeChanges: Bool) async {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DriveBackupURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let signIn = BackupReadSignIn()
            signIn.delaysRestore = true
            let routeNotification = Notification.Name("BackupRoute-\(UUID())")
            let model = GoogleDriveBackupModel(
                signIn: signIn, client: GoogleDriveBackupClient(urlSession: transport), routeChangeNotification: routeNotification
            )
            let restore = Task { await model.refresh() }
            var iterator = signIn.started.makeAsyncIterator()
            _ = await iterator.next()
            let old = signIn.session
            #expect(model.isBusy)
            if routeChanges {
                signIn.delaysRestore = false
                signIn.session = GoogleSession(
                    account: GoogleCalendarAccount(id: "replacement", displayName: "Replacement", email: ""),
                    accessToken: "test-token", grantedScopes: GoogleOAuthScope.drive
                )
                NotificationCenter.default.post(name: routeNotification, object: nil)
                #expect(await pollUntil { model.account?.id == "replacement" })
            } else {
                signIn.hasPreviousSignIn = false
                NotificationCenter.default.post(name: signIn.sessionDidChangeNotification, object: GoogleAuthSessionChangeReason.disconnected)
                #expect(await pollUntil { !model.isBusy && !model.hasConnection })
            }
            signIn.completeRestore(old)
            await restore.value
            #expect(model.account?.id == (routeChanges ? "replacement" : nil))
            #expect(model.isAuthorized == routeChanges)
            #expect(model.files.isEmpty == !routeChanges)
        }

        @Test(arguments: [false, true])
        func importRejectsAChangedAccountOrRoute(routeChanges: Bool) async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DriveBackupURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let signIn = BackupReadSignIn()
            let model = GoogleDriveBackupModel(signIn: signIn, client: GoogleDriveBackupClient(urlSession: transport))
            await model.refresh()
            let file = try #require(model.files.first)
            signIn.session = GoogleSession(
                account: routeChanges ? signIn.session.account : GoogleCalendarAccount(id: "other", displayName: "Other", email: ""),
                accessToken: "test-token", grantedScopes: GoogleOAuthScope.drive,
                apiBaseURL: routeChanges ? URL(string: "https://other.example/proxy")! : signIn.session.apiBaseURL
            )
            let database = try AppDatabaseManager(path: ":memory:")
            let service = BackupService(
                dbQueue: database.dbQueue, applicationSupportURL: FileManager.default.temporaryDirectory.appending(path: "backup-\(UUID())")
            )
            await #expect(throws: GoogleSignInError.self) { try await model.importBackup(file, using: service) }
            #expect(!model.isAuthorized)
            #expect(model.files.isEmpty)
            #expect(model.account == nil)
        }

    }

    @MainActor
    private final class BackupReadSignIn: GoogleSignInProviding {
        let isConfigured = true
        var hasPreviousSignIn = true
        let sessionDidChangeNotification = Notification.Name("BackupReadSignIn-\(UUID())")
        var disconnectCount = 0
        var delaysRestore = false
        let started: AsyncStream<Bool>
        private let start: AsyncStream<Bool>.Continuation
        private var pending: CheckedContinuation<GoogleSession, Never>?
        var session = GoogleSession(
            account: GoogleCalendarAccount(id: "test", displayName: "Test", email: ""),
            accessToken: "test-token", grantedScopes: GoogleOAuthScope.drive
        )

        init() {
            (started, start) = AsyncStream.makeStream()
        }

        func restorePreviousSignIn() async throws -> GoogleSession {
            guard delaysRestore else { return session }
            return await withCheckedContinuation { continuation in
                pending = continuation
                start.yield(true)
            }
        }

        func completeRestore(_ result: GoogleSession? = nil) {
            pending?.resume(returning: result ?? session)
            pending = nil
        }

        func signIn(withPresentingWindow _: NSWindow, requestedScopes _: Set<String>) async throws -> GoogleSession { session }
        func refreshCurrentSession() async throws -> GoogleSession? { session }
        func disconnect() async throws {
            disconnectCount += 1
            hasPreviousSignIn = false
        }
    }
#endif
