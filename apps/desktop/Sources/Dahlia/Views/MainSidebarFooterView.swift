import SwiftUI

struct MainSidebarFooterView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation

    let workspaces: [WorkspaceRecord]
    let currentWorkspace: WorkspaceRecord?
    var updateController: AppUpdateController
    let onSelectWorkspace: (WorkspaceRecord) -> Void

    @State private var isAccountMenuHovered = false
    @State private var isHelpHovered = false
    @State private var isMCPPresented = false
    @State private var dahliaAccountController = DahliaCloudAccountController.shared
    @State private var workspaceAISettings = WorkspaceAISettingsModel.shared

    var body: some View {
        let connection = workspaceAISettings.accountConnectionID.flatMap { connectionID in
            dahliaAccountController.connections.first(where: { $0.id == connectionID })
        }
        let signedInConnections = dahliaAccountController.connections.filter(\.isSignedIn)
        let accountWorkspaces = Self.workspaces(workspaces, linkedTo: workspaceAISettings.accountConnectionID)
        HStack(spacing: 4) {
            MainSidebarAccountMenuButton(
                workspaces: accountWorkspaces,
                currentWorkspace: currentWorkspace,
                connections: signedInConnections,
                currentConnectionID: connection?.id,
                isLocalAccount: workspaceAISettings.isLocalAccount,
                isLocalAccountAvailable: workspaces.contains { $0.accountConnectionId == nil },
                onSelectWorkspace: onSelectWorkspace,
                onOpenSettings: showSettings,
                onSelectAccount: selectAccount,
                onAccountAction: accountAction
            )
            .disabled(workspaceAISettings.isSwitchingRuntime)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 44)
            .background(
                isAccountMenuHovered ? DahliaDesign.sidebarHighlightColor : .clear,
                in: .rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
            )
            .contentShape(.rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius))
            .onContinuousHover { phase in
                isAccountMenuHovered = phase != .ended
            }
            .help(L10n.accountAndWorkspaceMenuDescription)

            if workspaceAISettings.isSwitchingRuntime {
                ProgressView()
                    .controlSize(.small)
                    .help(L10n.switchingAIAccount)
            }

            if updateController.isUpdateAvailable {
                MainSidebarUpdateBadge(updateController: updateController)
            }

            MainSidebarHelpMenuButton(onOpenMCP: showMCP)
                .frame(width: 30, height: 30)
                .background(
                    isHelpHovered ? DahliaDesign.sidebarHighlightColor : .clear,
                    in: .rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
                )
                .contentShape(.rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius))
                .help(L10n.help)
                .onHover { isHelpHovered = $0 }
        }
        .padding(.horizontal, 10)
        .frame(height: MainSidebarLayout.footerHeight)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
        }
        .sheet(isPresented: $isMCPPresented) {
            MCPModalView(
                workspaces: workspaces,
                currentWorkspace: currentWorkspace
            )
        }
    }

    private func showMCP() {
        isMCPPresented = true
    }

    private func showSettings(_ category: SettingsCategory?) {
        mainWindowNavigation.openSettings(category: category)
    }

    private func accountAction() {
        if let connectionID = workspaceAISettings.accountConnectionID,
           let connection = dahliaAccountController.connections.first(where: { $0.id == connectionID }) {
            if connection.isSignedIn {
                dahliaAccountController.requestSignOut(connectionID: connection.id)
            } else {
                dahliaAccountController.startReauthentication(connectionID: connection.id)
            }
        } else {
            mainWindowNavigation.openDahliaSignIn()
        }
    }

    private func selectAccount(_ connection: DahliaAccountConnection?) {
        guard let workspace = Self.workspaceToSelect(
            from: workspaces,
            currentWorkspace: currentWorkspace,
            connectionID: connection?.id
        ) else { return }
        onSelectWorkspace(workspace)
    }

    static func workspaces(_ workspaces: [WorkspaceRecord], linkedTo connectionID: UUID?) -> [WorkspaceRecord] {
        workspaces
            .filter { $0.accountConnectionId == connectionID }
            .sorted {
                ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
            }
    }

    static func workspaceToSelect(
        from workspaces: [WorkspaceRecord],
        currentWorkspace: WorkspaceRecord?,
        connectionID: UUID?
    ) -> WorkspaceRecord? {
        guard currentWorkspace?.accountConnectionId != connectionID else { return nil }
        return Self.workspaces(workspaces, linkedTo: connectionID).first
    }
}
