import SwiftUI

struct VaultSettingsView: View {
    let appDatabase: AppDatabaseManager?
    var model: VaultManagementModel
    let currentVault: VaultRecord?
    let onRenameVault: (VaultRecord) -> Void

    @State private var isShowingFolderPicker = false
    @State private var isShowingRenameAlert = false
    @State private var pendingRemoval: VaultRecord?
    @State private var pendingRename: VaultRecord?
    @State private var proposedName = ""

    var body: some View {
        Form {
            Section {
                if model.isLoading, model.vaults.isEmpty {
                    ProgressView(L10n.loadingVaults)
                } else if model.vaults.isEmpty {
                    Label(L10n.noVaults, systemImage: "externaldrive.badge.plus")
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                } else {
                    ForEach(model.vaults) { vault in
                        LabeledContent {
                            vaultActions(for: vault)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vault.name)
                                    Text(vault.path)
                                        .font(.footnote)
                                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                }
                            } icon: {
                                Image(systemName: "externaldrive")
                                    .dahliaFixedSymbol()
                                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                            }
                            .help(vault.path)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(L10n.registeredVaults)

                    Spacer()

                    Button(L10n.addVault, systemImage: "plus", action: showFolderPicker)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help(L10n.openFolderAsVaultDescription)
                }
            } footer: {
                if model.vaults.isEmpty, !model.isLoading {
                    Text(L10n.noVaultsDescription)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isRemovingVault || model.isRenamingVault)
        .overlay {
            if model.isRemovingVault {
                ProgressView(L10n.removingVault)
            }
        }
        .onChange(of: currentVault?.id) {
            if pendingRemoval?.id == currentVault?.id {
                pendingRemoval = nil
            }
        }
        .task(id: appDatabase != nil) {
            await model.configure(appDatabase: appDatabase)
        }
        .fileImporter(
            isPresented: $isShowingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderImport
        )
        .fileDialogDefaultDirectory(VaultManagementModel.defaultVaultURL)
        .alert(
            pendingRename.map { L10n.renameVault($0.name) } ?? L10n.rename,
            isPresented: $isShowingRenameAlert
        ) {
            TextField(L10n.vaultName, text: $proposedName)
            Button(L10n.save, action: renameVault)
                .disabled(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(L10n.cancel, role: .cancel, action: clearRenameRequest)
        }
        .confirmationDialog(
            pendingRemoval.map { L10n.removeVaultConfirmation($0.name) } ?? "",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let vault = pendingRemoval {
                Button(L10n.removeVault, role: .destructive) {
                    removeVault(vault)
                }
            }
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(L10n.removeVaultConfirmationDescription)
        }
    }

    private func showFolderPicker() {
        isShowingFolderPicker = true
    }

    private func vaultActions(for vault: VaultRecord) -> some View {
        Menu(L10n.actions, systemImage: "ellipsis.circle") {
            Button(L10n.rename, systemImage: "pencil", action: { requestRename(vault) })

            if vault.id != currentVault?.id {
                Button(L10n.removeVault, systemImage: "minus", role: .destructive) {
                    pendingRemoval = vault
                }
            }
        }
        .labelStyle(.iconOnly)
        .dahliaFixedSymbol()
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(L10n.actions)
    }

    private func handleFolderImport(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            Task {
                _ = await model.registerVault(at: url, markAsOpened: false)
            }
        case let .failure(error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            model.presentFolderSelectionError(error)
        }
    }

    private func requestRename(_ vault: VaultRecord) {
        pendingRename = vault
        proposedName = vault.name
        isShowingRenameAlert = true
    }

    private func renameVault() {
        guard let vault = pendingRename else { return }
        let name = proposedName
        clearRenameRequest()
        Task {
            if let renamedVault = await model.renameVault(vault, to: name) {
                onRenameVault(renamedVault)
            }
        }
    }

    private func clearRenameRequest() {
        pendingRename = nil
        proposedName = ""
    }

    private func removeVault(_ vault: VaultRecord) {
        Task {
            _ = await model.removeVault(vault, currentVaultId: currentVault?.id)
            pendingRemoval = nil
        }
    }
}
