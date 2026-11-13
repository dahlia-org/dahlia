#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct WorkspaceSettingsAccountGroupTests {
        @Test
        func groupsByAccountIdentityAndKeepsCreationOrder() {
            let accountID = UUID.v7()
            var gateway = workspace(createdAt: 1)
            gateway.databricksConnectionId = accountID
            var server = workspace(createdAt: 2)
            server.accountConnectionId = accountID
            let local = workspace(createdAt: 3)
            var earlierLocal = workspace(createdAt: 0)
            earlierLocal.lastOpenedAt = .now
            let otherAccountID = UUID.v7()
            var otherServer = workspace(createdAt: 4)
            otherServer.accountConnectionId = otherAccountID

            let groups = WorkspaceSettingsAccountGroup.grouped([local, otherServer, server, gateway, earlierLocal])

            #expect(groups.map(\.id) == [.local, .databricks(accountID), .dahlia(accountID), .dahlia(otherAccountID)])
            #expect(groups.map { $0.workspaces.map(\.id) } == [[earlierLocal.id, local.id], [gateway.id], [server.id], [otherServer.id]])
            #expect(WorkspaceSettingsAccountGroup.grouped([]).isEmpty)
        }

        @Test
        func keepsEmptyCreationAccountsVisibleWithoutDuplicatingPopulatedGroups() {
            let gatewayID = UUID.v7()
            let emptyGatewayID = UUID.v7()
            var gateway = workspace(createdAt: 0)
            gateway.databricksConnectionId = gatewayID

            let groups = WorkspaceSettingsAccountGroup.grouped(
                [gateway],
                including: [.local, .databricks(gatewayID), .databricks(emptyGatewayID), .local]
            )

            #expect(groups.map(\.id) == [.local, .databricks(gatewayID), .databricks(emptyGatewayID)])
            #expect(groups.map { $0.workspaces.map(\.id) } == [[], [gateway.id], []])
            #expect(WorkspaceSettingsAccountGroup.grouped([], including: [.local]).first?.id == .local)
        }

        @Test
        func movingAnAccountRegroupsWithoutLosingTheWorkspace() {
            let local = workspace(createdAt: 0)
            var moved = workspace(createdAt: 1)
            moved.databricksConnectionId = .v7()
            #expect(WorkspaceSettingsAccountGroup.grouped([local, moved]).count == 2)

            moved.databricksConnectionId = nil
            let groups = WorkspaceSettingsAccountGroup.grouped([moved, local])

            #expect(groups.count == 1)
            #expect(groups.first?.id == .local)
            #expect(groups.first?.workspaces.map(\.id) == [local.id, moved.id])
        }

        private func workspace(createdAt: TimeInterval) -> WorkspaceRecord {
            WorkspaceRecord(
                id: .v7(), path: nil, name: "Default",
                createdAt: Date(timeIntervalSince1970: createdAt), lastOpenedAt: .distantPast
            )
        }
    }
#endif
