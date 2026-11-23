import SwiftUI

struct MainSidebarFooterView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation

    let workspaces: [WorkspaceRecord]
    let currentWorkspace: WorkspaceRecord?
    var updateController: AppUpdateController
    let onSelectWorkspace: (WorkspaceRecord) -> Void
    let unprocessedRecordingCount: Int
    let onShowUnprocessedRecordings: () -> Void

    @State private var isAccountMenuHovered = false
    @State private var isHelpHovered = false
    @State private var isMCPPresented = false
    @State private var dahliaAccountController = DahliaCloudAccountController.shared
    @State private var workspaceAISettings = WorkspaceAISettingsModel.shared

    var body: some View {
        // Dahlia accounts are listed by their sign-in state; the app's one account is always the current one.
        let signedInConnections = dahliaAccountController.connections.filter(\.isSignedIn)
        HStack(spacing: 4) {
            MainSidebarAccountMenuButton(
                connections: signedInConnections,
                currentConnectionID: nil,
                isLocalAccount: true,
                onOpenSettings: showSettings,
                onSelectAccount: selectAccount,
                onAddAccount: { mainWindowNavigation.openDahliaSignIn() },
                onAccountAction: accountAction,
                unprocessedRecordingCount: unprocessedRecordingCount,
                onShowUnprocessedRecordings: onShowUnprocessedRecordings
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
        mainWindowNavigation.openDahliaSignIn()
    }

    /// The app has one account. Choosing it opens its oldest workspace when none is open, creating one on first use.
    private func selectAccount(_ connection: DahliaAccountConnection?) {
        guard connection == nil, currentWorkspace == nil else { return }
        if let workspace = workspaces.min(by: { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) {
            onSelectWorkspace(workspace)
            return
        }
        Task { @MainActor in
            if let workspace = await WorkspaceAISettingsModel.shared.accountWorkspace() {
                onSelectWorkspace(workspace)
            }
        }
    }
}
