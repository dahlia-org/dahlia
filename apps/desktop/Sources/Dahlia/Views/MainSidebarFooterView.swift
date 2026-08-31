import SwiftUI

struct MainSidebarFooterView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation

    let vaults: [VaultRecord]
    let currentVault: VaultRecord?
    var updateController: AppUpdateController
    let onSelectVault: (VaultRecord) -> Void

    @State private var isAccountMenuHovered = false
    @State private var isHelpHovered = false
    @State private var isMCPPresented = false
    @State private var dahliaAccountController = DahliaCloudAccountController.shared

    var body: some View {
        let accountPresentation = Self.accountPresentation(for: dahliaAccountController.connections)
        let connection = accountPresentation.connection
        HStack(spacing: 4) {
            MainSidebarAccountMenuButton(
                vaults: vaults,
                currentVault: currentVault,
                account: connection?.account,
                accountOrigin: connection?.origin,
                isCloudAccount: connection?.isCloud,
                accountSummary: accountPresentation.count > 1
                    ? L10n.dahliaAccountCount(accountPresentation.count)
                    : nil,
                onSelectVault: onSelectVault,
                onManageVaults: showVaultManager,
                onOpenSettings: showSettings,
                onAccountAction: accountAction
            )
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
            .help(L10n.accountAndVaultMenuDescription)

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
                vaults: vaults,
                currentVault: currentVault
            )
        }
    }

    private func showVaultManager() {
        mainWindowNavigation.openSettings(category: .vault)
    }

    private func showMCP() {
        isMCPPresented = true
    }

    private func showSettings(_ category: SettingsCategory?) {
        mainWindowNavigation.openSettings(category: category)
    }

    private func accountAction() {
        if let connection = Self.accountPresentation(for: dahliaAccountController.connections).connection {
            dahliaAccountController.startSignOut(connectionID: connection.id)
        } else {
            mainWindowNavigation.openDahliaSignIn()
        }
    }

    static func accountPresentation(
        for connections: [DahliaAccountConnection]
    ) -> (connection: DahliaAccountConnection?, count: Int) {
        let signedInConnections = connections.filter(\.isSignedIn)
        return (
            signedInConnections.count == 1 ? signedInConnections[0] : nil,
            signedInConnections.count
        )
    }
}
