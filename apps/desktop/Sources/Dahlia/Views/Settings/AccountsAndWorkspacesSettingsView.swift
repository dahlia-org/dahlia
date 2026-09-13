import SwiftUI

struct AccountsAndWorkspacesSettingsView: View {
    let appDatabase: AppDatabaseManager?
    var workspaceModel: WorkspaceManagementModel
    let currentWorkspace: WorkspaceRecord?
    let accountController: DahliaCloudAccountController
    let onShowSignIn: () -> Void
    let onUpdateWorkspace: (WorkspaceRecord) -> Void

    var body: some View {
        Form {
            DahliaAccountsSettingsView(
                controller: accountController,
                currentWorkspace: currentWorkspace,
                onShowSignIn: onShowSignIn
            )
            WorkspaceSettingsView(
                appDatabase: appDatabase,
                model: workspaceModel,
                currentWorkspace: currentWorkspace,
                accountConnections: accountController.connections,
                onUpdateWorkspace: onUpdateWorkspace
            )
        }
        .formStyle(.grouped)
        .onChange(of: accountController.connections) {
            Task { await workspaceModel.loadWorkspaces() }
        }
        .onChange(of: workspaceAssignments) {
            Task { await accountController.reload() }
        }
    }

    private var workspaceAssignments: [String] {
        workspaceModel.workspaces.map { "\($0.id.uuidString):\($0.accountConnectionId?.uuidString ?? "local")" }
    }
}
