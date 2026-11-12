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
            let model = GoogleDriveBackupModel(signIn: signIn, client: GoogleDriveBackupClient(urlSession: transport), openAccount: { .local })
            await model.refresh()
            #expect(model.isAuthorized)
            #expect(model.files.count == 2)
            await model.disconnect()
            #expect(!model.isAuthorized)
            #expect(!model.hasConnection)
            #expect(model.files.isEmpty)
            #expect(signIn.disconnectCount == 1)
        }

        @Test
        func anAccountSwitchDiscardsThePreviousAccountsRestore() async {
            let signIn = BackupReadSignIn()
            signIn.delaysRestore = true
            var owner = CodexRuntimeProvider.local
            let model = GoogleDriveBackupModel(signIn: signIn, openAccount: { owner })
            var started = signIn.started.makeAsyncIterator()
            let load = Task { await model.refresh() }
            _ = await started.next()
            owner = .databricks(connectionID: .v7())
            model.resetForAccount()
            signIn.completeRestore()
            await load.value
            #expect(!model.isAuthorized)
            #expect(model.account == nil)
            #expect(model.files.isEmpty)
            #expect(!model.isBusy)
        }
    }

    @MainActor
    private final class BackupReadSignIn: GoogleSignInProviding {
        let isConfigured = true
        var hasPreviousSignIn = true
        let sessionDidChangeNotification = Notification.Name("BackupReadSignIn")
        var disconnectCount = 0
        var delaysRestore = false
        let started: AsyncStream<Bool>
        private let start: AsyncStream<Bool>.Continuation
        private var pending: CheckedContinuation<GoogleSession, Never>?
        private let session = GoogleSession(
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

        func completeRestore() {
            pending?.resume(returning: session)
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
