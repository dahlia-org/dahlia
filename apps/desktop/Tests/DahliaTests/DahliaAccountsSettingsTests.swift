#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct DahliaAccountsSettingsTests {
        @Test
        func settingsSwitchesToTheSameWorkspaceAsTheAccountMenu() {
            let connection = makeConnection(isSignedIn: true)
            let local = makeWorkspace(connectionID: nil)
            let first = makeWorkspace(connectionID: connection.id, createdAt: .distantPast)
            let second = makeWorkspace(connectionID: connection.id)
            let workspaces = [second, local, first]
            var selected: WorkspaceRecord?
            let view = makeView(current: local, workspaces: workspaces) { selected = $0 }

            view.selectAccount(connection)

            #expect(selected == first)
            #expect(selected == MainSidebarFooterView.workspaceToSelect(
                from: workspaces, currentWorkspace: local, connectionID: connection.id
            ))

            selected = nil
            makeView(current: first, workspaces: workspaces) { selected = $0 }.selectAccount(nil)
            #expect(selected == local)
            #expect(local.accountConnectionId == nil)
            #expect(first.accountConnectionId == connection.id)
        }

        @Test
        func settingsDoesNotSwitchWhenUnavailable() {
            let connection = makeConnection(isSignedIn: true)
            let local = makeWorkspace(connectionID: nil)
            let server = makeWorkspace(connectionID: connection.id)
            var selections = 0
            let select: (WorkspaceRecord) -> Void = { _ in selections += 1 }

            makeView(current: local, workspaces: [local, server], canSwitch: false, onSelect: select)
                .selectAccount(connection)
            makeView(current: server, workspaces: [local, server], canSwitch: false, onSelect: select)
                .selectAccount(nil)
            makeView(current: local, workspaces: [local], onSelect: select)
                .selectAccount(connection)
            makeView(current: server, workspaces: [server], onSelect: select)
                .selectAccount(connection)
            makeView(current: local, workspaces: [local], onSelect: select)
                .selectAccount(nil)

            let signedOut = makeConnection(isSignedIn: false)
            makeView(current: local, workspaces: [makeWorkspace(connectionID: signedOut.id)], onSelect: select)
                .selectAccount(signedOut)

            #expect(selections == 0)
        }

        @Test
        func settingsCanSelectLocalAccountWithoutACurrentWorkspace() {
            let local = makeWorkspace(connectionID: nil)
            var selected: WorkspaceRecord?

            makeView(current: nil, workspaces: [local]) { selected = $0 }.selectAccount(nil)

            #expect(selected == local)
        }

        private func makeView(
            current: WorkspaceRecord?,
            workspaces: [WorkspaceRecord],
            canSwitch: Bool = true,
            onSelect: @escaping (WorkspaceRecord) -> Void
        ) -> DahliaAccountsSettingsView {
            DahliaAccountsSettingsView(
                controller: DahliaCloudAccountController(configuration: nil),
                currentWorkspace: current,
                workspaces: workspaces,
                canSwitchAccount: canSwitch,
                onSelectWorkspace: onSelect,
                onShowSignIn: {}
            )
        }

        private func makeConnection(isSignedIn: Bool) -> DahliaAccountConnection {
            DahliaAccountConnection(
                record: DahliaAccountConnectionRecord(
                    id: .v7(), origin: "https://server.example.com", clientID: "test", createdAt: .now
                ),
                account: isSignedIn ? DahliaCloudAccount(id: "test", name: "Test", email: nil) : nil,
                isCloud: false,
                workspaceCount: 1
            )
        }

        private func makeWorkspace(connectionID: UUID?, createdAt: Date = .now) -> WorkspaceRecord {
            WorkspaceRecord(
                id: .v7(), path: nil, name: "Test", createdAt: createdAt, lastOpenedAt: .now,
                accountConnectionId: connectionID
            )
        }
    }
#endif
