import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MCPAccessScopeTests {
        @Test
        func accountAndWorkspaceScopesAreExclusiveAndMatchWorkspaceOwnership() {
            let serverID = UUID.v7()
            let databricksID = UUID.v7()
            let local = workspace()
            var server = workspace()
            server.accountConnectionId = serverID
            // Server ownership takes precedence over a legacy provider association.
            server.databricksConnectionId = databricksID
            var databricks = workspace()
            databricks.databricksConnectionId = databricksID
            let workspaces = [local, server, databricks]

            for (account, expected) in [(WorkspaceAccountChoice.local, local), (.dahlia(serverID), server), (.databricks(databricksID), databricks)] {
                #expect(MCPAccessScope.resolve(account: account, workspaceID: nil, workspaces: workspaces) == .account(account))
                #expect(MCPAccessScope.resolve(account: account, workspaceID: expected.id, workspaces: workspaces) == .workspace(expected.id))
                for other in workspaces where other.id != expected.id {
                    #expect(MCPAccessScope.resolve(account: account, workspaceID: other.id, workspaces: workspaces) == nil)
                }
            }
            #expect(MCPAccessScope.resolve(account: nil, workspaceID: nil, workspaces: []) == .all)
            #expect(MCPAccessScope.resolve(account: .local, workspaceID: UUID.v7(), workspaces: workspaces) == nil)
            #expect(MCPAccessScope.resolve(account: nil, workspaceID: local.id, workspaces: workspaces) == nil)
        }

        @Test
        func sameNameAcrossAccountsDoesNotExposeUUIDs() {
            let local = workspace()
            var server = workspace()
            server.accountConnectionId = .v7()
            #expect(MCPWorkspaceDisplayName.resolve(for: local, among: [local, server]) == "Default")
            #expect(MCPWorkspaceDisplayName.resolve(for: server, among: [local, server]) == "Default")
            let duplicate = workspace()
            #expect(MCPWorkspaceDisplayName.resolve(for: local, among: [local, duplicate]) == "Default — \(local.id.uuidString.suffix(8))")
        }

        private func workspace() -> WorkspaceRecord {
            WorkspaceRecord(id: .v7(), name: "Default", createdAt: .distantPast, lastOpenedAt: .distantPast)
        }
    }
#endif
