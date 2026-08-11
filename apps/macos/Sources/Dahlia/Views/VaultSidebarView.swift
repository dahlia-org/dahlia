import SwiftUI

struct VaultSidebarView: View {
    let vaults: [VaultRecord]
    @Binding var selectedVaultId: UUID?
    let currentVaultId: UUID?
    let onAdd: () -> Void
    let onRemove: (VaultRecord) -> Void

    @State private var isShowingRemovalConfirmation = false

    private var selectedVault: VaultRecord? {
        guard let selectedVaultId else { return nil }
        return vaults.first(where: { $0.id == selectedVaultId })
    }

    var body: some View {
        List(selection: $selectedVaultId) {
            ForEach(vaults) { vault in
                HStack {
                    Label {
                        VStack(alignment: .leading) {
                            Text(vault.name)
                            Text(vault.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: "externaldrive")
                    }

                    Spacer()

                    if vault.id == currentVaultId {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.currentVault)
                    }
                }
                .tag(vault.id)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(L10n.vault)
        .onDeleteCommand(perform: requestRemoval)
        .toolbar {
            ToolbarItemGroup {
                Button(L10n.addVault, systemImage: "plus", action: onAdd)
                    .help(L10n.openFolderAsVaultDescription)

                Button(L10n.removeVault, systemImage: "minus", action: requestRemoval)
                    .disabled(selectedVault == nil || selectedVault?.id == currentVaultId)
                    .help(selectedVault?.id == currentVaultId ? L10n.currentVaultRemoveDescription : L10n.removeVault)
                    .confirmationDialog(
                        L10n.removeVaultConfirmation(selectedVault?.name ?? ""),
                        isPresented: $isShowingRemovalConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(L10n.removeVault, role: .destructive, action: confirmRemoval)
                        Button(L10n.cancel, role: .cancel) {}
                    } message: {
                        Text(L10n.removeVaultConfirmationDescription)
                    }
            }
        }
        .toolbar(removing: .sidebarToggle)
    }

    private func requestRemoval() {
        guard let selectedVault, selectedVault.id != currentVaultId else { return }
        isShowingRemovalConfirmation = true
    }

    private func confirmRemoval() {
        guard let selectedVault else { return }
        onRemove(selectedVault)
    }
}
