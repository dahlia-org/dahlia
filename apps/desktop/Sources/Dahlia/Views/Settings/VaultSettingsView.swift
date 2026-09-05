import SwiftUI

struct VaultSettingsView: View {
    let appDatabase: AppDatabaseManager?
    var model: VaultManagementModel
    let currentVault: VaultRecord?
    let accountConnections: [DahliaAccountConnection]
    let onUpdateVault: (VaultRecord) -> Void

    @State private var isShowingFolderPicker = false
    @State private var isShowingCreateAlert = false
    @State private var isShowingRenameAlert = false
    @State private var pendingRemoval: VaultRecord?
    @State private var pendingRename: VaultRecord?
    @State private var pendingExportFolderVault: VaultRecord?
    @State private var proposedName = ""

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
            .alert(L10n.createNewVault, isPresented: $isShowingCreateAlert) {
                TextField(L10n.vaultName, text: $proposedName)
                Button(L10n.create, action: createVault)
                    .disabled(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L10n.cancel, role: .cancel, action: clearCreateRequest)
            } message: {
                Text(L10n.vaultNameDescription)
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
                                Text(vault.path ?? L10n.noLocalExportFolder)
                                    .font(.footnote)
                                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        .help(vault.path ?? L10n.noLocalExportFolder)

                        Spacer()

                        VaultAccountPicker(
                            vault: vault,
                            connections: accountConnections,
                            onSelect: { await requestServerAdoption(for: vault, connectionID: $0) }
                        )
                        .disabled(vault.accountConnectionId != nil)
                        if vault.syncRecoveryState == "updateRequired" {
                            Label(L10n.vaultSyncUpdateRequired, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        } else if model.blockedSyncVaultIDs.contains(vault.id) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(L10n.vaultSyncConflict)
                                .accessibilityLabel(L10n.vaultSyncConflict)
                        } else if vault.syncRecoveryState != nil {
                            Label(
                                vault.syncRecoveryState == "recovering" ? L10n.vaultSyncRecovering : L10n.vaultSyncRecoveryPending,
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(.caption).foregroundStyle(.secondary)
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
                            Button(L10n.addVault) {
                                Task { _ = await model.registerCloudVault(vault) }
                            }
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(L10n.vault)

                Spacer()

                Button(L10n.addVault, systemImage: "plus", action: showCreateAlert)
                    .buttonStyle(.dahlia(.primary))
                    .controlSize(.small)
                    .help(L10n.vaultNameDescription)
            }
        } footer: {
            if model.vaults.isEmpty, !model.isLoading {
                Text(L10n.noVaultsDescription)
            }
        }
    }

    private func showCreateAlert() {
        proposedName = ""
        isShowingCreateAlert = true
    }

    private func vaultActions(for vault: VaultRecord) -> some View {
        Menu(L10n.actions, systemImage: "ellipsis.circle") {
            if vault.allowsCanonicalEdits {
                Button(L10n.rename, systemImage: "pencil", action: { requestRename(vault) })
            }

            Button(vault.path == nil ? L10n.setLocalExportFolder : L10n.changeLocalExportFolder, systemImage: "folder") {
                pendingExportFolderVault = vault
                isShowingFolderPicker = true
            }
            if vault.path != nil {
                Button(L10n.removeLocalExportFolder, systemImage: "folder.badge.minus") {
                    Task {
                        if let updated = await model.setExportFolder(for: vault, to: nil) {
                            onUpdateVault(updated)
                        }
                    }
                }
            }

            if model.conflictedSyncVaultIDs.contains(vault.id) {
                Button(L10n.useServerVersion, systemImage: "icloud.and.arrow.down") {
                    Task { await model.acceptServerSyncVersion(for: vault) }
                }
                if vault.syncRole != "member" {
                    Button(L10n.reapplyLocalVersion, systemImage: "arrow.up.circle") {
                        Task { await model.reapplyLocalSyncVersion(for: vault) }
                    }
                }
            }

            if model.validationBlockedSyncVaultIDs.contains(vault.id) {
                Button(L10n.retrySync, systemImage: "arrow.clockwise") {
                    Task { await model.retryInvalidSyncTransaction(for: vault) }
                }
                Button(L10n.useServerVersion, systemImage: "icloud.and.arrow.down", role: .destructive) {
                    Task { await model.discardInvalidSyncTransaction(for: vault) }
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
                if let vault = pendingExportFolderVault,
                   let updated = await model.setExportFolder(for: vault, to: url) {
                    onUpdateVault(updated)
                }
                pendingExportFolderVault = nil
            }
        case let .failure(error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            pendingExportFolderVault = nil
            model.presentFolderSelectionError(error)
        }
    }

    private func createVault() {
        let name = proposedName
        clearCreateRequest()
        Task { _ = await model.createVault(named: name) }
    }

    private func clearCreateRequest() {
        proposedName = ""
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
                onUpdateVault(renamedVault)
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
