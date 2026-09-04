import SwiftUI

struct AccountsAndVaultsSettingsView: View {
    let appDatabase: AppDatabaseManager?
    var vaultModel: VaultManagementModel
    let currentVault: VaultRecord?
    let accountController: DahliaCloudAccountController
    let onShowSignIn: () -> Void
    let onUpdateVault: (VaultRecord) -> Void

    var body: some View {
        Form {
            DahliaAccountsSettingsView(
                controller: accountController,
                onShowSignIn: onShowSignIn
            )
            VaultSettingsView(
                appDatabase: appDatabase,
                model: vaultModel,
                currentVault: currentVault,
                accountConnections: accountController.connections,
                onRenameVault: onUpdateVault
            )
            AccountSettingsView()
        }
        .formStyle(.grouped)
        .onChange(of: accountController.connections) {
            Task { await vaultModel.loadVaults() }
        }
        .onChange(of: vaultAssignments) {
            Task { await accountController.reload() }
        }
    }

    private var vaultAssignments: [String] {
        vaultModel.vaults.map { "\($0.id.uuidString):\($0.accountConnectionId?.uuidString ?? "local")" }
    }
}
