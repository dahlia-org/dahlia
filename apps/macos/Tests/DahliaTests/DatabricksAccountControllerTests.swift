#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct DatabricksAccountControllerTests {
        @Test func loadsAndRemovesTheWorkspaceConnection() async {
            let first = DatabricksConnection(id: UUID(), host: "https://one.example.com")
            let memory = DatabricksTestStorage(connection: first)
            let controller = DatabricksAccountController(service: DatabricksOAuthService(storage: memory.storage))
            await controller.load()
            #expect(controller.connection == first)
            #expect(await controller.remove(first.id))
            #expect(controller.connection == nil)
        }

        @Test func invalidWorkspaceDoesNotChangeExistingConnections() async {
            let memory = DatabricksTestStorage()
            let controller = DatabricksAccountController(service: DatabricksOAuthService(storage: memory.storage))
            #expect(await controller.signIn(workspaceURL: "http://example.com") == nil)
            #expect(controller.errorMessage != nil)
            #expect(!controller.isBusy)
            #expect(controller.connection == nil)
        }
    }
#endif
