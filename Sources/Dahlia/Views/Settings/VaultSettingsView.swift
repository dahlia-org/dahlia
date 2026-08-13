import SwiftUI

struct VaultSettingsView: View {
    let appDatabase: AppDatabaseManager?
    var model: VaultManagementModel
    let currentVault: VaultRecord?
    let canSwitchVault: Bool
    let onSelectVault: (VaultRecord) -> Void

    @State private var isShowingFolderPicker = false
    @State private var pendingRemoval: VaultRecord?

    var body: some View {
        Form {
            Section {
                Button(L10n.addVault, systemImage: "folder.badge.plus", action: showFolderPicker)
            } footer: {
                Text(L10n.openFolderAsVaultDescription)
            }

            if model.isLoading, model.vaults.isEmpty {
                Section {
                    ProgressView(L10n.loadingVaults)
                }
            } else if model.vaults.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(L10n.noVaults, systemImage: "externaldrive.badge.plus")
                    } description: {
                        Text(L10n.noVaultsDescription)
                    }
                }
            } else {
                ForEach(model.vaults) { vault in
                    Section(vault.name) {
                        LabeledContent(L10n.location) {
                            Text(vault.path)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }

                        if vault.id == currentVault?.id {
                            LabeledContent {
                                Label(L10n.currentVault, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            } label: {
                                Text(L10n.status)
                                Text(L10n.currentVaultRemoveDescription)
                            }
                        } else {
                            Button(L10n.openVault, systemImage: "folder") {
                                onSelectVault(vault)
                            }
                            .disabled(!canSwitchVault)

                            Button(L10n.removeVault, systemImage: "minus", role: .destructive) {
                                pendingRemoval = vault
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if model.isRemovingVault {
                ProgressView(L10n.removingVault)
            }
        }
        .formStyle(.grouped)
        .disabled(model.isRemovingVault)
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

    private func handleFolderImport(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            Task {
                guard let vault = await model.registerVault(at: url), canSwitchVault else { return }
                onSelectVault(vault)
            }
        case let .failure(error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            model.presentFolderSelectionError(error)
        }
    }

    private func removeVault(_ vault: VaultRecord) {
        Task {
            _ = await model.removeVault(vault)
            pendingRemoval = nil
        }
    }
}
