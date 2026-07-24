import Foundation
@testable import DahliaMeetingAccess
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    struct MCPWorkspaceNotificationTests {
        @Test(.timeLimit(.minutes(1)))
        func projectMutationNotifiesTheRunningApplication() async throws {
            let fixture = try Fixture()
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            let center = DistributedNotificationCenter.default()
            let (notifications, continuation) = AsyncStream<Void>.makeStream()
            let observer = center.addObserver(
                forName: DahliaWorkspaceChangeNotification.name(vaultID: fixture.primaryVaultID),
                object: nil,
                queue: nil
            ) { _ in
                continuation.yield()
            }
            defer {
                center.removeObserver(observer)
                continuation.finish()
            }
            var iterator = notifications.makeAsyncIterator()

            _ = try store.createProject(
                leafName: "Notified",
                parentProjectID: nil,
                projectType: .internal
            )
            #expect(await iterator.next() != nil)
        }
    }
#endif
