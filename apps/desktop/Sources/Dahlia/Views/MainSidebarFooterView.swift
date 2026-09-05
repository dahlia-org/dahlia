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
    @State private var vaultAISettings = VaultAISettingsModel.shared

    var body: some View {
        let connection = vaultAISettings.accountConnectionID.flatMap { connectionID in
            dahliaAccountController.connections.first(where: { $0.id == connectionID })
        }
        let signedInConnections = dahliaAccountController.connections.filter(\.isSignedIn)
        let accountVaults = Self.vaults(vaults, linkedTo: vaultAISettings.accountConnectionID)
        HStack(spacing: 4) {
            MainSidebarAccountMenuButton(
                vaults: accountVaults,
                currentVault: currentVault,
                connections: signedInConnections,
                currentConnectionID: connection?.id,
                isLocalAccount: vaultAISettings.isLocalAccount,
                isLocalAccountAvailable: vaults.contains { $0.accountConnectionId == nil },
                onSelectVault: onSelectVault,
                onOpenSettings: showSettings,
                onSelectAccount: selectAccount,
                onAccountAction: accountAction
            )
            .disabled(vaultAISettings.isSwitchingRuntime)
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

            if vaultAISettings.isSwitchingRuntime {
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
                vaults: vaults,
                currentVault: currentVault
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
        if let connectionID = vaultAISettings.accountConnectionID,
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
        guard let vault = Self.vaultToSelect(
            from: vaults,
            currentVault: currentVault,
            connectionID: connection?.id
        ) else { return }
        onSelectVault(vault)
    }

    static func vaults(_ vaults: [VaultRecord], linkedTo connectionID: UUID?) -> [VaultRecord] {
        vaults
            .filter { $0.accountConnectionId == connectionID }
            .sorted {
                ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
            }
    }

    static func vaultToSelect(
        from vaults: [VaultRecord],
        currentVault: VaultRecord?,
        connectionID: UUID?
    ) -> VaultRecord? {
        guard currentVault?.accountConnectionId != connectionID else { return nil }
        return Self.vaults(vaults, linkedTo: connectionID).first
    }
}
