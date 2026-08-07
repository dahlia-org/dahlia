import SwiftUI

struct MCPPreviewOptionsView: View {
    @Binding var selectedClient: MCPClient
    @Binding var selectedVaultID: UUID?
    @Binding var isWriteEnabled: Bool

    let availableVaults: [VaultRecord]

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text(L10n.mcpClient)
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                Text(L10n.vault)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L10n.vault, selection: $selectedVaultID) {
                    ForEach(availableVaults) { vault in
                        Text(MCPVaultDisplayName.resolve(for: vault, among: availableVaults))
                            .tag(Optional(vault.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading) {
                Text(L10n.mcpAllowWriteAccess)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(L10n.mcpAllowWriteAccess, isOn: $isWriteEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
