import SwiftUI

struct MainSidebarFooterView: View {
    @Environment(MainWindowNavigation.self) private var mainWindowNavigation

    let vaults: [VaultRecord]
    let currentVault: VaultRecord?
    var updateController: AppUpdateController
    let onSelectVault: (VaultRecord) -> Void

    @State private var isAccountMenuHovered = false
    @State private var isSettingsHovered = false
    @State private var isMCPPresented = false

    var body: some View {
        HStack(spacing: 4) {
            MainSidebarAccountMenuButton(
                vaults: vaults,
                currentVault: currentVault,
                onSelectVault: onSelectVault,
                onManageVaults: showVaultManager,
                onOpenMCP: showMCP
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30)
            .background(
                isAccountMenuHovered ? Color.primary.opacity(0.08) : .clear,
                in: .rect(cornerRadius: 6)
            )
            .contentShape(.rect(cornerRadius: 6))
            .onContinuousHover { phase in
                isAccountMenuHovered = phase != .ended
            }
            .help(L10n.currentVaultDescription)

            if updateController.isUpdateAvailable {
                MainSidebarUpdateBadge(updateController: updateController)
            }

            Button {
                mainWindowNavigation.openSettings()
            } label: {
                Label(L10n.settings, systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .frame(width: 30, height: 30)
                    .background(isSettingsHovered ? Color.primary.opacity(0.08) : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.settingsMenuItem)
            .accessibilityLabel(L10n.settings)
            .onHover { isSettingsHovered = $0 }
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
}
