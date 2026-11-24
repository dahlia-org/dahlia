import SwiftUI

struct MCPPreviewOptionsView: View {
    @Binding var selectedWorkspaceID: UUID?
    let availableWorkspaces: [WorkspaceRecord]

    var body: some View {
        Picker(L10n.workspace, selection: $selectedWorkspaceID) {
            Text(L10n.mcpAllWorkspaces).font(.dahliaBody).tag(nil as UUID?)
            ForEach(availableWorkspaces) { workspace in
                Text(MCPWorkspaceDisplayName.resolve(for: workspace, among: availableWorkspaces))
                    .font(.dahliaBody)
                    .tag(Optional(workspace.id))
            }
        }
        .pickerStyle(.menu)
    }
}
