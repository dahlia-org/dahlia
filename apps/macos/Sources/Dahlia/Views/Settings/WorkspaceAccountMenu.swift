import SwiftUI

struct WorkspaceAccountMenu: View {
    let workspace: WorkspaceRecord
    let connections: [DahliaAccountConnection]
    let databricksAccounts: [DatabricksConnection]
    let onSelect: (WorkspaceAccountChoice) -> Void

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Menu(L10n.moveWorkspaceToAccount, systemImage: "arrow.right.arrow.left") {
            if !settings.hideLocalAccount {
                accountButton(.local)
            }
            ForEach(databricksAccounts) { account in
                accountButton(.databricks(account.id))
            }
            ForEach(connections) { connection in
                accountButton(.dahlia(connection.id))
                    .disabled(!connection.isSignedIn || !connection.supportsWorkspaceSync)
            }
        }
    }

    private func accountButton(_ choice: WorkspaceAccountChoice) -> some View {
        Button {
            onSelect(choice)
        } label: {
            Text(choice.displayName(connections: connections, databricksAccounts: databricksAccounts))
                .font(.dahliaBody)
        }
        .disabled(choice == WorkspaceAccountChoice(workspace))
    }
}
