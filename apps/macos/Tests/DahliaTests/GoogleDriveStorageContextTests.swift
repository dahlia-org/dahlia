#if canImport(Testing)
    import AppKit
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    private final class StorageGoogleSignIn: GoogleSignInProviding {
        let isConfigured = true
        let hasPreviousSignIn = true
        var isDisconnectPending = false
        let sessionDidChangeNotification = Notification.Name("StorageGoogleSignIn")
        var onRefresh: (() async throws -> Void)?
        var returnedToken = false
        let session = GoogleSession(
            account: .init(id: "fixture", displayName: "Fixture", email: "fixture@example.com"),
            accessToken: "original-token", grantedScopes: GoogleOAuthScope.drive
        )

        func restorePreviousSignIn() async throws -> GoogleSession { session }
        func signIn(withPresentingWindow _: NSWindow, requestedScopes _: Set<String>) async throws -> GoogleSession { session }
        func disconnect() async throws {}
        func refreshCurrentSession() async throws -> GoogleSession? {
            try await onRefresh?()
            returnedToken = true
            return session
        }
    }

    @MainActor
    struct GoogleDriveStorageContextTests {
        @Test(arguments: ["pending", "completed", "relogin", "other", "refresh"])
        func authorizationChangesDuringTheFolderReadAreCheckedBeforeHTTP(_ change: String) async throws {
            let id = UUID.v7()
            let repository = try await providerSettingsRepository(accounts: [.google(connectionID: id)])
            let signIn = StorageGoogleSignIn()
            let host = "context-\(UUID().uuidString.lowercased()).example"
            let session = StorageStubURLProtocol.session(host: host) { _ in .json(#"{"files":[]}"#) }
            defer {
                session.invalidateAndCancel()
                StorageStubURLProtocol.reset(host: host)
            }
            let storage = try await GoogleDriveStorage(
                accountID: id, signIn: signIn, repository: repository,
                baseURL: #require(URL(string: "https://\(host)/")), session: session
            )
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let (started, continuation) = AsyncStream.makeStream(of: Void.self)
            var blocker: Task<Void, Error>?
            signIn.onRefresh = {
                blocker = Task.detached {
                    try await repository.dbQueue.write { _ in
                        continuation.yield(())
                        release.wait()
                    }
                }
                for await _ in started {
                    break
                }
            }
            let request = Task { try await storage.list(directory: "backup") }
            // The token has returned on MainActor; its caller is now waiting behind the held DB writer.
            #expect(await pollUntil { signIn.returnedToken })
            if change == "other" {
                GoogleSignInAdapter.invalidateStorageAuthorization(accountID: .v7())
            } else if change != "refresh" {
                GoogleSignInAdapter.invalidateStorageAuthorization(accountID: id)
                signIn.isDisconnectPending = change == "pending"
            }
            release.signal()
            if change == "other" || change == "refresh" {
                #expect(try await request.value.isEmpty)
                #expect(StorageStubURLProtocol.requests(host: host).count == 1)
            } else {
                await #expect(throws: CancellationError.self) { try await request.value }
                #expect(StorageStubURLProtocol.requests(host: host).isEmpty)
                await #expect(throws: CancellationError.self) { try await storage.validate() }
            }
            try await blocker?.value
        }
    }
#endif
