import Foundation
@testable import Dahlia
@testable import DahliaMeetingAccess
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
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
                name: "Notified",
                parentProjectID: nil,
                projectType: .internal
            )
            #expect(await iterator.next() != nil)
        }

        @Test(.timeLimit(.minutes(1)))
        func projectMutationRefreshesTheRunningSidebar() async throws {
            let fixture = try Fixture()
            let vault = VaultRecord(
                id: fixture.primaryVaultID,
                path: fixture.primaryVaultURL.path,
                name: "Primary",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let settings = AppSettings()
            let sidebar = SidebarViewModel(settings: settings)
            settings.currentVault = vault
            sidebar.setAppDatabase(fixture.manager)
            defer {
                sidebar.setAppDatabase(nil)
            }

            #expect(await waitUntil { sidebar.isProjectCatalogLoaded })
            let store = try fixture.store(vaultID: fixture.primaryVaultID, allowsWrites: true)
            _ = try store.createProject(
                name: "Sidebar Refresh",
                parentProjectID: nil,
                projectType: .personal
            )

            #expect(await waitUntil {
                sidebar.allProjectItems.contains { $0.projectDisplayName == "Sidebar Refresh" }
            })
        }

        private func waitUntil(
            timeout: Duration = .seconds(5),
            _ predicate: @MainActor () -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout

            while clock.now < deadline, !Task.isCancelled {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return predicate()
        }
    }
#endif
