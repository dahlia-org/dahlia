import SwiftUI

struct VaultSettingsView: View {
    let appDatabase: AppDatabaseManager?
    var model: VaultManagementModel
    let currentVault: VaultRecord?
    let accountConnections: [DahliaAccountConnection]
    let onRenameVault: (VaultRecord) -> Void

    @State private var isShowingFolderPicker = false
    @State private var isShowingRenameAlert = false
    @State private var pendingRemoval: VaultRecord?
    @State private var pendingRename: VaultRecord?
    @State private var proposedName = ""
    @State private var pendingCloudVault: CloudVaultRecord?

    var body: some View {
        sections
            .disabled(
                model.isRemovingVault || model.isRenamingVault
                    || model.updatingVaultAccountID != nil
            )
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

    private var sections: some View {
        Section {
            if model.isLoading, model.vaults.isEmpty {
                ProgressView(L10n.loadingVaults)
            } else if model.vaults.isEmpty {
                Label(L10n.noVaults, systemImage: "externaldrive.badge.plus")
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
            } else {
                ForEach(model.vaults) { vault in
                    HStack {
                        HStack {
                            Image(systemName: "externaldrive")
                                .dahliaFixedSymbol()
                                .foregroundStyle(DahliaDesign.secondaryTextColor)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(vault.name)
                                Text(vault.path)
                                    .font(.footnote)
                                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        .help(vault.path)

                        Spacer()

                        VaultAccountPicker(
                            vault: vault,
                            connections: accountConnections,
                            onSelect: { await requestServerAdoption(for: vault, connectionID: $0) }
                        )
                        .disabled(vault.accountConnectionId != nil)
                        if model.blockedSyncVaultIDs.contains(vault.id) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(L10n.vaultSyncConflict)
                        }
                        vaultActions(for: vault)
                    }
                }
                if !model.cloudVaults.isEmpty {
                    Divider()
                    ForEach(model.cloudVaults) { vault in
                        HStack {
                            Label(vault.name, systemImage: "icloud")
                            Spacer()
                            Button(L10n.chooseLocalFolder) {
                                pendingCloudVault = vault
                                isShowingFolderPicker = true
                            }
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(L10n.vault)

                Spacer()

                Button(L10n.addVault, systemImage: "plus", action: showFolderPicker)
                    .buttonStyle(.dahlia(.primary))
                    .controlSize(.small)
                    .help(L10n.openFolderAsVaultDescription)
            }
        } footer: {
            if model.vaults.isEmpty, !model.isLoading {
                Text(L10n.noVaultsDescription)
            }
        }
    }

    private func showFolderPicker() {
        pendingCloudVault = nil
        isShowingFolderPicker = true
    }

    private func vaultActions(for vault: VaultRecord) -> some View {
        Menu(L10n.actions, systemImage: "ellipsis.circle") {
            if vault.allowsCanonicalEdits {
                Button(L10n.rename, systemImage: "pencil", action: { requestRename(vault) })
            }

            if model.blockedSyncVaultIDs.contains(vault.id) {
                Button(L10n.useServerVersion, systemImage: "icloud.and.arrow.down") {
                    Task { await model.acceptServerSyncVersion(for: vault) }
                }
                if vault.syncRole != "member" {
                    Button(L10n.reapplyLocalVersion, systemImage: "arrow.up.circle") {
                        Task { await model.reapplyLocalSyncVersion(for: vault) }
                    }
                }
            }

            if vault.id != currentVault?.id, !vault.requiresServerDeletionBeforeRemoval {
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
                if let pendingCloudVault {
                    _ = await model.registerCloudVault(pendingCloudVault, at: url)
                    self.pendingCloudVault = nil
                } else {
                    _ = await model.registerVault(at: url, markAsOpened: false)
                }
            }
        case let .failure(error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            pendingCloudVault = nil
            model.presentFolderSelectionError(error)
        }
    }

    private func requestRename(_ vault: VaultRecord) {
        guard vault.allowsCanonicalEdits else { return }
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

    private func requestServerAdoption(for vault: VaultRecord, connectionID: UUID?) async -> UUID? {
        guard let connectionID,
              let connection = accountConnections.first(where: { $0.id == connectionID })
        else { return vault.accountConnectionId }
        await model.requestServerAdoption(for: vault, connection: connection)
        return vault.accountConnectionId
    }
}
