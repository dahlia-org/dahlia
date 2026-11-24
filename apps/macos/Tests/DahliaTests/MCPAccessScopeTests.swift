import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MCPAccessScopeTests {
        @Test
        func scopeIsEveryWorkspaceOrOneThatIsStillOnThisMac() {
            let workspaces = [workspace(), workspace()]

            #expect(MCPAccessScope.resolve(workspaceID: nil, workspaces: []) == .all)
            #expect(MCPAccessScope.all.arguments.isEmpty)
            for workspace in workspaces {
                #expect(MCPAccessScope.resolve(workspaceID: workspace.id, workspaces: workspaces) == .workspace(workspace.id))
            }
            #expect(MCPAccessScope.resolve(workspaceID: UUID.v7(), workspaces: workspaces) == nil)
        }

        @Test
        func sameNameWorkspacesAreTellApartByIDSuffix() {
            let local = workspace()
            let duplicate = workspace()
            #expect(MCPWorkspaceDisplayName.resolve(for: local, among: [local, duplicate]) == "Default — \(local.id.uuidString.suffix(8))")
        }

        private func workspace() -> WorkspaceRecord {
            WorkspaceRecord(id: .v7(), name: "Default", createdAt: .distantPast, lastOpenedAt: .distantPast)
        }
    }
#endif
