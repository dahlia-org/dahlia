import SwiftUI

struct MCPPreviewOptionsView: View {
    @Binding var selectedAccount: WorkspaceAccountChoice?
    @Binding var selectedWorkspaceID: UUID?
    let accounts: [WorkspaceAccountChoice]
    let availableWorkspaces: [WorkspaceRecord]
    let accountName: (WorkspaceAccountChoice) -> String

    var body: some View {
        Picker(L10n.account, selection: $selectedAccount) {
            Text(L10n.mcpAllAccounts).font(.dahliaBody).tag(nil as WorkspaceAccountChoice?)
            ForEach(accounts, id: \.self) { account in
                Text(accountName(account)).font(.dahliaBody).tag(Optional(account))
            }
        }
        .pickerStyle(.menu)
        .onChange(of: selectedAccount) {
            selectedWorkspaceID = nil
        }

        if let selectedAccount {
            Picker(L10n.workspace, selection: $selectedWorkspaceID) {
                Text(L10n.mcpAccountWorkspaces).font(.dahliaBody).tag(nil as UUID?)
                ForEach(availableWorkspaces) { workspace in
                    Text(MCPWorkspaceDisplayName.resolve(
                        for: workspace, among: availableWorkspaces, accountName: accountName(selectedAccount)
                    ))
                    .font(.dahliaBody)
                    .tag(Optional(workspace.id))
                }
            }
            .pickerStyle(.menu)
            .id(selectedAccount)
        }
    }
}
