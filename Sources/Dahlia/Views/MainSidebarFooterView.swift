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

    var body: some View {
        HStack(spacing: 4) {
            MainSidebarAccountMenuButton(
                vaults: vaults,
                currentVault: currentVault,
                onSelectVault: onSelectVault,
                onManageVaults: showVaultManager,
                onOpenSettings: showSettings
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30)
            .background(
                isAccountMenuHovered ? DahliaDesign.sidebarHighlightColor : .clear,
                in: .rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
            )
            .contentShape(.rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius))
            .onContinuousHover { phase in
                isAccountMenuHovered = phase != .ended
            }
            .help(L10n.currentVaultDescription)

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

    private func showSettings() {
        mainWindowNavigation.openSettings()
    }
}
