#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    struct WorkspaceSettingsAccountGroupTests {
        @Test
        func groupsByAccountIdentityAndKeepsCreationOrder() {
            let accountID = UUID.v7()
            var server = workspace(createdAt: 2)
            server.accountConnectionId = accountID
            let local = workspace(createdAt: 3)
            var earlierLocal = workspace(createdAt: 0)
            earlierLocal.lastOpenedAt = .now
            let otherAccountID = UUID.v7()
            var otherServer = workspace(createdAt: 4)
            otherServer.accountConnectionId = otherAccountID

            let groups = WorkspaceSettingsAccountGroup.grouped([local, otherServer, server, earlierLocal])

            #expect(groups.map(\.id) == [.local, .dahlia(accountID), .dahlia(otherAccountID)])
            #expect(groups.map { $0.workspaces.map(\.id) } == [[earlierLocal.id, local.id], [server.id], [otherServer.id]])
            #expect(WorkspaceSettingsAccountGroup.grouped([]).isEmpty)
        }

        @Test
        func keepsEmptyCreationAccountsVisibleWithoutDuplicatingPopulatedGroups() {
            let serverID = UUID.v7()
            let emptyServerID = UUID.v7()
            var server = workspace(createdAt: 0)
            server.accountConnectionId = serverID

            let groups = WorkspaceSettingsAccountGroup.grouped(
                [server],
                including: [.local, .dahlia(serverID), .dahlia(emptyServerID), .local]
            )

            #expect(groups.map(\.id) == [.local, .dahlia(serverID), .dahlia(emptyServerID)])
            #expect(groups.map { $0.workspaces.map(\.id) } == [[], [server.id], []])
            #expect(WorkspaceSettingsAccountGroup.grouped([], including: [.local]).first?.id == .local)
        }

        @Test
        func movingAnAccountRegroupsWithoutLosingTheWorkspace() {
            let local = workspace(createdAt: 0)
            var moved = workspace(createdAt: 1)
            moved.accountConnectionId = .v7()
            #expect(WorkspaceSettingsAccountGroup.grouped([local, moved]).count == 2)

            moved.accountConnectionId = nil
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
