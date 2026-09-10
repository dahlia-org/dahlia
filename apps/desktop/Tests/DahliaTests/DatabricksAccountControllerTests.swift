#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct DatabricksAccountControllerTests {
        @Test func loadsAppConnectionsAndRemovesOnlySelectedConnection() async {
            let first = DatabricksConnection(id: UUID(), name: "One", host: "https://one.example.com")
            let second = DatabricksConnection(id: UUID(), name: "Two", host: "https://two.example.com")
            let memory = DatabricksTestStorage(connections: [first, second])
            let controller = DatabricksAccountController(service: DatabricksOAuthService(storage: memory.storage))
            await controller.load()
            #expect(controller.connections == [first, second])
            #expect(await controller.remove(first.id))
            #expect(controller.connections == [second])
        }

        @Test func invalidWorkspaceDoesNotChangeExistingConnections() async {
            let memory = DatabricksTestStorage()
            let controller = DatabricksAccountController(service: DatabricksOAuthService(storage: memory.storage))
            #expect(await controller.signIn(workspaceURL: "http://example.com") == nil)
            #expect(controller.errorMessage != nil)
            #expect(!controller.isBusy)
            #expect(controller.connections.isEmpty)
        }
    }
#endif
