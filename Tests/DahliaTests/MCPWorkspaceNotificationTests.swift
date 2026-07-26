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
            let settings = AppSettings.shared
            let previousVault = settings.currentVault
            let previousInstructionID = settings.selectedInstructionID
            let sidebar = SidebarViewModel()
            settings.currentVault = vault
            sidebar.setAppDatabase(fixture.manager)
            defer {
                sidebar.setAppDatabase(nil)
                settings.currentVault = previousVault
                settings.selectedInstructionID = previousInstructionID
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

        private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
            for _ in 0 ..< 1_000 {
                if predicate() { return true }
                await Task.yield()
            }
            return predicate()
        }
    }
#endif
