import SwiftUI

struct MCPPreviewOptionsView: View {
    @Binding var selectedClient: MCPClient
    @Binding var selectedWorkspaceID: UUID?
    @Binding var isWriteEnabled: Bool

    let availableWorkspaces: [WorkspaceRecord]

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text(L10n.mcpClient)
                    .font(.subheadline)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)

                Picker(L10n.mcpClient, selection: $selectedClient) {
                    ForEach(MCPClient.allCases) { client in
                        Text(client.displayName).tag(client)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading) {
                Text(L10n.workspace)
                    .font(.subheadline)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)

                Picker(L10n.workspace, selection: $selectedWorkspaceID) {
                    Text(L10n.mcpAllWorkspaces).tag(nil as UUID?)
                    ForEach(availableWorkspaces) { workspace in
                        Text(MCPWorkspaceDisplayName.resolve(for: workspace, among: availableWorkspaces))
                            .tag(Optional(workspace.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading) {
                Text(L10n.mcpAllowWriteAccess)
                    .font(.subheadline)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)

                Toggle(L10n.mcpAllowWriteAccess, isOn: $isWriteEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
