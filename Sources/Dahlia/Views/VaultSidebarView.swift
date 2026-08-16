import SwiftUI

struct VaultSidebarView: View {
    let vaults: [VaultRecord]
    @Binding var selectedVaultId: UUID?
    let currentVaultId: UUID?
    var updateController: AppUpdateController
    let onAdd: () -> Void
    let onRemove: (VaultRecord) -> Void

    @Environment(MainWindowNavigation.self) private var mainWindowNavigation
    @State private var isShowingRemovalConfirmation = false

    private var selectedVault: VaultRecord? {
        guard let selectedVaultId else { return nil }
        return vaults.first(where: { $0.id == selectedVaultId })
    }

    var body: some View {
        VStack(spacing: 0) {
            DahliaWindowHeader(reservesWindowControls: true) {
                Text(L10n.vault)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if updateController.isUpdateAvailable {
                    DahliaWindowHeaderIconButton(
                        label: updateButtonLabel,
                        systemImage: "arrow.down.circle.fill",
                        helpAlignment: .bottomTrailing,
                        action: updateController.showUpdateDialog
                    )
                }

                DahliaWindowHeaderIconButton(
                    label: L10n.addVault,
                    systemImage: "plus",
                    helpAlignment: .bottomTrailing,
                    action: onAdd
                )
                .disabled(mainWindowNavigation.isShowingSettings)

                DahliaWindowHeaderIconButton(
                    label: removeButtonLabel,
                    systemImage: "minus",
                    helpAlignment: .bottomTrailing,
                    action: requestRemoval
                )
                .disabled(
                    mainWindowNavigation.isShowingSettings
                        || selectedVault == nil
                        || isCurrentVaultSelected
                )
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
            .tint(DahliaDesign.sidebarSelectionColor)
            .onDeleteCommand(perform: requestRemoval)
        }
    }

    private var removeButtonLabel: String {
        isCurrentVaultSelected ? L10n.currentVaultRemoveDescription : L10n.removeVault
    }

    private var isCurrentVaultSelected: Bool {
        selectedVault?.id == currentVaultId
    }

    private var updateButtonLabel: String {
        guard let version = updateController.availableVersion else {
            return L10n.updateAvailable
        }
        return L10n.updateAvailableVersion(version)
    }

    private func requestRemoval() {
        guard selectedVault != nil, !isCurrentVaultSelected else { return }
        isShowingRemovalConfirmation = true
    }

    private func confirmRemoval() {
        guard let selectedVault else { return }
        onRemove(selectedVault)
    }
}
