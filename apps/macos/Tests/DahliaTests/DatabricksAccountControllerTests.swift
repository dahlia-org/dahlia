#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct DatabricksAccountControllerTests {
        @Test func signOutRequiresConfirmationAndCancellationKeepsTheConnection() async throws {
            let connection = DatabricksConnection(id: UUID(), host: "https://one.example.com", email: "test@example.com")
            let memory = DatabricksTestStorage()
            memory.state.withLock { $0.connections = [connection] }
            let service = DatabricksOAuthService(storage: memory.storage)
            let suite = "DatabricksSignOut-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = WorkspaceAISettingsModel(
                setupDefaults: defaults, activateRuntime: { _ in }, databricksService: service
            )
            await model.reloadDatabricksConnections()
            let workspace = WorkspaceRecord(
                id: .v7(), path: nil, name: "Test", createdAt: .now, lastOpenedAt: .now,
                databricksConnectionId: connection.id
            )
            model.activate(workspace: workspace)

            #expect(model.pendingDatabricksSignOut == nil)
            model.requestDatabricksSignOut()
            #expect(model.pendingDatabricksSignOut == connection)
            #expect(try await service.connections() == [connection])

            model.cancelDatabricksSignOut()
            #expect(model.pendingDatabricksSignOut == nil)
            await model.confirmDatabricksSignOut()
            #expect(try await service.connections() == [connection])
            #expect(model.databricksAccountConnectionID == connection.id)
        }

        @Test func removesOnlyTheChosenWorkspace() async throws {
            let first = DatabricksConnection(id: UUID(), host: "https://one.example.com")
            let second = DatabricksConnection(id: UUID(), host: "https://two.example.com")
            let memory = DatabricksTestStorage()
            memory.state.withLock { $0.connections = [first, second] }
            let service = DatabricksOAuthService(storage: memory.storage)
            let controller = DatabricksAccountController(service: service)

            _ = controller
            try await service.remove(connectionID: first.id)

            #expect(try await service.connections() == [second])
            #expect(try await service.currentConnection() == second)
        }

        @Test func invalidWorkspaceDoesNotChangeExistingConnections() async throws {
            let memory = DatabricksTestStorage()
            let service = DatabricksOAuthService(storage: memory.storage)
            let controller = DatabricksAccountController(service: service)
            #expect(await controller.signIn(workspaceURL: "http://example.com") == nil)
            #expect(controller.errorMessage != nil)
            #expect(!controller.isBusy)
            #expect(try await service.connections().isEmpty)
        }
    }
#endif
