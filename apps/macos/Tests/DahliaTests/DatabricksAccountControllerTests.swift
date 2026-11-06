#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct DatabricksAccountControllerTests {
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
