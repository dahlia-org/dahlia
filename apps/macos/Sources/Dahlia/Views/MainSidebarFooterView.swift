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
        HStack(spacing: 4) {
            MainSidebarAccountMenuButton(
                connections: signedInConnections,
                currentConnectionID: connection?.id,
                isLocalAccount: workspaceAISettings.isLocalAccount,
                databricksAccounts: workspaceAISettings.databricksConnections,
                currentDatabricksAccountID: workspaceAISettings.isDatabricksAccount
                    ? workspaceAISettings.databricksAccountConnectionID : nil,
                onOpenSettings: showSettings,
                onSelectAccount: selectAccount,
                onSelectDatabricksAccount: { selectLocalAccount(databricks: $0) },
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
            .help(L10n.accountMenuDescription)

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
        } else if workspaceAISettings.isDatabricksAccount {
            // Its workspaces return to the Local Account, which then opens.
            Task { await workspaceAISettings.signOutOfDatabricksAccount() }
        } else {
            mainWindowNavigation.openDahliaSignIn()
        }
    }

    private func selectAccount(_ connection: DahliaAccountConnection?) {
        guard connection != nil else { return selectLocalAccount(databricks: nil) }
        guard let workspace = Self.workspaceToSelect(
            from: workspaces,
            currentWorkspace: currentWorkspace,
            connectionID: connection?.id
        ) else { return }
        onSelectWorkspace(workspace)
    }

    private func selectLocalAccount(databricks: UUID?) {
        Self.selectLocalAccount(
            databricks: databricks,
            workspaces: workspaces,
            currentWorkspace: currentWorkspace,
            onSelectWorkspace: onSelectWorkspace
        )
    }

    /// The Local Account and each Databricks account (`databricks`, a connected workspace) open their own workspaces;
    /// each gets its first one on first use. All keep their data on this Mac.
    static func selectLocalAccount(
        databricks: UUID?,
        workspaces: [WorkspaceRecord],
        currentWorkspace: WorkspaceRecord?,
        onSelectWorkspace: @escaping (WorkspaceRecord) -> Void
    ) {
        if let workspace = workspaceToSelect(
            from: workspaces, currentWorkspace: currentWorkspace, connectionID: nil, databricks: databricks
        ) {
            onSelectWorkspace(workspace)
            return
        }
        guard Self.workspaces(workspaces, linkedTo: nil, databricks: databricks).isEmpty else { return }
        Task { @MainActor in
            if let workspace = await WorkspaceAISettingsModel.shared.accountWorkspace(databricksConnectionID: databricks) {
                onSelectWorkspace(workspace)
            }
        }
    }

    static func workspaces(
        _ workspaces: [WorkspaceRecord],
        linkedTo connectionID: UUID?,
        databricks: UUID? = nil
    ) -> [WorkspaceRecord] {
        workspaces
            .filter { $0.accountConnectionId == connectionID && $0.databricksConnectionId == databricks }
            .sorted {
                ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
            }
    }

    static func workspaceToSelect(
        from workspaces: [WorkspaceRecord],
        currentWorkspace: WorkspaceRecord?,
        connectionID: UUID?,
        databricks: UUID? = nil
    ) -> WorkspaceRecord? {
        // The listed copy is current; the open workspace's copy may predate a move between accounts.
        let current = currentWorkspace.flatMap { open in workspaces.first { $0.id == open.id } } ?? currentWorkspace
        guard current.map({ $0.accountConnectionId != connectionID || $0.databricksConnectionId != databricks }) ?? true
        else { return nil }
        return Self.workspaces(workspaces, linkedTo: connectionID, databricks: databricks).first
    }
}
