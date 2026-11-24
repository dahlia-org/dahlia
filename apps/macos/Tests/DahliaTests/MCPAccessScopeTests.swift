import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MCPAccessScopeTests {
        @Test
        func accountAndWorkspaceScopesAreExclusiveAndMatchWorkspaceOwnership() {
            let local = workspace()
            let other = workspace()
            // Every workspace belongs to the app's account (Local).
            let workspaces = [local, other]

            #expect(MCPAccessScope.resolve(account: .local, workspaceID: nil, workspaces: workspaces) == .account(.local))
            for workspace in workspaces {
                #expect(MCPAccessScope.resolve(account: .local, workspaceID: workspace.id, workspaces: workspaces) == .workspace(workspace.id))
            }
            #expect(MCPAccessScope.resolve(account: nil, workspaceID: nil, workspaces: []) == .all)
            #expect(MCPAccessScope.resolve(account: .local, workspaceID: UUID.v7(), workspaces: workspaces) == nil)
            #expect(MCPAccessScope.resolve(account: nil, workspaceID: local.id, workspaces: workspaces) == nil)
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
