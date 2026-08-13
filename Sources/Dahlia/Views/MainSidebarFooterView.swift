import AppKit
import SwiftUI

struct MainSidebarFooterView: View {
    static let verticalPadding: CGFloat = 8

    @Environment(\.openWindow) private var openWindow
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
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
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
                    .padding(7)
                    .background(isSettingsHovered ? Color.primary.opacity(0.08) : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.settingsMenuItem)
            .accessibilityLabel(L10n.settings)
            .onHover { isSettingsHovered = $0 }
        }
        .padding(2)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Self.verticalPadding)
        .sheet(isPresented: $isMCPPresented) {
            MCPModalView(
                vaults: vaults,
                currentVault: currentVault
            )
        }
    }

    private func showVaultManager() {
        openWindow(id: WindowID.vaultManager)
    }

    private func showMCP() {
        isMCPPresented = true
    }
}
