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
            let store = try fixture.store(workspaceID: fixture.primaryWorkspaceID, allowsWrites: true)
            let center = DistributedNotificationCenter.default()
            let (notifications, continuation) = AsyncStream<Void>.makeStream()
            let observer = center.addObserver(
                forName: DahliaWorkspaceChangeNotification.name(workspaceID: fixture.primaryWorkspaceID),
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
            let workspace = WorkspaceRecord(
                id: fixture.primaryWorkspaceID,
                path: fixture.primaryWorkspaceURL.path,
                name: "Primary",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let settings = AppSettings()
            let sidebar = SidebarViewModel(settings: settings)
            settings.currentWorkspace = workspace
            sidebar.setAppDatabase(fixture.manager)
            defer {
                sidebar.setAppDatabase(nil)
            }

            #expect(await waitUntil { sidebar.isProjectCatalogLoaded })
            let store = try fixture.store(workspaceID: fixture.primaryWorkspaceID, allowsWrites: true)
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
            timeout: Duration = testPollTimeout,
            _ predicate: @MainActor () -> Bool
        ) async -> Bool {
            await pollUntil(timeout: timeout) { predicate() }
        }
    }
#endif
