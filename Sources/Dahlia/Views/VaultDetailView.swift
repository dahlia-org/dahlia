import SwiftUI

struct VaultDetailView: View {
    let vault: VaultRecord?
    let hasRegisteredVaults: Bool
    let isCurrentVault: Bool
    let onOpen: () -> Void
    let onAdd: () -> Void

    var body: some View {
        if let vault {
            Form {
                Section(L10n.vaultDetails) {
                    LabeledContent(L10n.vaultName, value: vault.name)
                    LabeledContent(L10n.location) {
                        Text(vault.path)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    if isCurrentVault {
                        LabeledContent {
                            Label(L10n.currentVault, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        } label: {
                            Text(L10n.status)
                            Text(L10n.currentVaultRemoveDescription)
                        }
                    }
                }

                Section {
                    Button(L10n.openVault, systemImage: "folder", action: onOpen)
                        .buttonStyle(.borderedProminent)
                        .disabled(isCurrentVault)
                } footer: {
                    Text(L10n.openVaultDescription)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(vault.name)
        } else if hasRegisteredVaults {
            ContentUnavailableView {
                Label(L10n.noVaultSelected, systemImage: "externaldrive")
            } description: {
                Text(L10n.selectVaultDescription)
            }
        } else {
            ContentUnavailableView {
                Label(L10n.noVaults, systemImage: "externaldrive.badge.plus")
            } description: {
                Text(L10n.noVaultsDescription)
            } actions: {
                Button(L10n.openFolderAsVault, systemImage: "folder.badge.plus", action: onAdd)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
