import SwiftUI

struct VaultSettingsView: View {
    let appDatabase: AppDatabaseManager?
    var model: VaultManagementModel
    let currentVault: VaultRecord?
    let accountConnections: [DahliaAccountConnection]
    let onRenameVault: (VaultRecord) -> Void
    let onUpdateVaultAccount: (VaultRecord) -> Void

    @State private var isShowingFolderPicker = false
    @State private var isShowingRenameAlert = false
    @State private var pendingRemoval: VaultRecord?
    @State private var pendingRename: VaultRecord?
    @State private var proposedName = ""
    @State private var pendingServerDeletion: VaultRecord?
    @State private var pendingBulkMeetingDeletion: VaultRecord?
    @State private var pendingCloudVault: CloudVaultRecord?

    var body: some View {
        sections
            .disabled(
                model.isRemovingVault || model.isRenamingVault
                    || model.updatingVaultAccountID != nil || model.updatingVaultSyncID != nil
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
            .confirmationDialog(
                L10n.deleteServerCopy,
                isPresented: Binding(
                    get: { pendingServerDeletion != nil },
                    set: { if !$0 { pendingServerDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let vault = pendingServerDeletion {
                    Button(L10n.deleteServerCopy, role: .destructive) {
                        Task {
                            _ = await model.deleteServerCopy(for: vault)
                            pendingServerDeletion = nil
                        }
                    }
                }
                Button(L10n.cancel, role: .cancel) {}
            } message: {
                Text(L10n.deleteServerCopyDescription)
            }
            .confirmationDialog(
                L10n.confirmBulkMeetingDeletion,
                isPresented: Binding(
                    get: { pendingBulkMeetingDeletion != nil },
                    set: { if !$0 { pendingBulkMeetingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let vault = pendingBulkMeetingDeletion {
                    Button(L10n.continueDeletion, role: .destructive) {
                        Task {
                            await model.approvePendingMeetingDeletions(for: vault)
                            pendingBulkMeetingDeletion = nil
                        }
                    }
                }
                Button(L10n.cancel, role: .cancel) {}
            } message: {
                Text(L10n.confirmBulkMeetingDeletionDescription(
                    pendingBulkMeetingDeletion.flatMap { model.pendingMeetingDeletionCounts[$0.id] } ?? 0
                ))
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
                            onSelect: { await updateAccountConnection(for: vault, connectionID: $0) }
                        )
                        Toggle(
                            L10n.vaultSync,
                            isOn: Binding(
                                get: { vault.syncEnabled },
                                set: { isEnabled in
                                    Task { _ = await model.updateSync(for: vault, isEnabled: isEnabled) }
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!vault.syncEnabled && !supportsSync(vault))
                        .help(vault.accountConnectionId == nil
                            ? L10n.vaultSyncRequiresAccount
                            : supportsSync(vault) ? L10n.vaultSyncDescription : L10n.vaultSyncRequiresReauthentication)
                        if vault.syncConflictJSON != nil {
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

    private func supportsSync(_ vault: VaultRecord) -> Bool {
        guard let connectionID = vault.accountConnectionId else { return false }
        return accountConnections.first(where: { $0.id == connectionID })?.supportsVaultSync == true
    }

    private func vaultActions(for vault: VaultRecord) -> some View {
        Menu(L10n.actions, systemImage: "ellipsis.circle") {
            Button(L10n.rename, systemImage: "pencil", action: { requestRename(vault) })

            if vault.syncConflictJSON != nil {
                Button(L10n.useServerVersion, systemImage: "icloud.and.arrow.down") {
                    Task { await model.acceptServerSyncVersion(for: vault) }
                }
                Button(L10n.reapplyLocalVersion, systemImage: "arrow.up.circle") {
                    Task { await model.reapplyLocalSyncVersion(for: vault) }
                }
            }

            if vault.syncConfirmedConnectionId != nil {
                Button(L10n.deleteServerCopy, systemImage: "icloud.slash", role: .destructive) {
                    pendingServerDeletion = vault
                }
            }

            if model.pendingMeetingDeletionCounts[vault.id] != nil {
                Button(L10n.confirmBulkMeetingDeletion, systemImage: "exclamationmark.triangle") {
                    pendingBulkMeetingDeletion = vault
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

    private func updateAccountConnection(for vault: VaultRecord, connectionID: UUID?) async -> UUID? {
        guard let updatedVault = await model.updateAccountConnection(for: vault, connectionID: connectionID) else {
            return vault.accountConnectionId
        }
        onUpdateVaultAccount(updatedVault)
        return updatedVault.accountConnectionId
    }
}
