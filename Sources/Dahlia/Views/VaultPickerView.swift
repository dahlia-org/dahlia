import SwiftUI

/// 保管庫の登録・選択・登録解除を行う画面。
struct VaultPickerView: View {
    let appDatabase: AppDatabaseManager?
    var model: VaultManagementModel
    let canSwitchVault: Bool
    let onVaultSelected: (VaultRecord) -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedVaultId: UUID?
    @State private var isShowingFolderPicker = false

    private var selectedVault: VaultRecord? {
        guard let selectedVaultId else { return nil }
        return model.vaults.first(where: { $0.id == selectedVaultId })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            VaultSidebarView(
                vaults: model.vaults,
                selectedVaultId: $selectedVaultId,
                currentVaultId: settings.currentVault?.id,
                onAdd: showFolderPicker,
                onRemove: removeVault
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            if model.isRemovingVault {
                ProgressView(L10n.removingVault)
            } else if model.isLoading, model.vaults.isEmpty {
                ProgressView(L10n.loadingVaults)
            } else {
                VaultDetailView(
                    vault: selectedVault,
                    hasRegisteredVaults: !model.vaults.isEmpty,
                    isCurrentVault: selectedVault?.id == settings.currentVault?.id,
                    canSwitchVault: canSwitchVault,
                    onOpen: openSelectedVault,
                    onAdd: showFolderPicker
                )
            }
        }
        .disabled(model.isRemovingVault)
        .frame(minWidth: 720, minHeight: 460)
        .task(id: appDatabase != nil) {
            await model.configure(appDatabase: appDatabase)
            reconcileSelection()
        }
        .fileImporter(
            isPresented: $isShowingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderImport
        )
        .fileDialogDefaultDirectory(VaultManagementModel.defaultVaultURL)
    }

    private func showFolderPicker() {
        isShowingFolderPicker = true
    }

    private func handleFolderImport(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            Task {
                guard let vault = await model.registerVault(at: url) else { return }
                selectedVaultId = vault.id
                openVault(vault)
            }
        case let .failure(error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            model.presentFolderSelectionError(error)
        }
    }

    private func reconcileSelection() {
        let preferredIds = [selectedVaultId, settings.currentVault?.id].compactMap(\.self)
        selectedVaultId = preferredIds.first(where: { id in
            model.vaults.contains(where: { $0.id == id })
        }) ?? model.vaults.first?.id
    }

    private func removeVault(_ vault: VaultRecord) {
        Task {
            if await model.removeVault(vault, currentVaultId: settings.currentVault?.id), selectedVaultId == vault.id {
                selectedVaultId = model.vaults.first?.id
            }
        }
    }

    private func openSelectedVault() {
        guard let selectedVault else { return }
        openVault(selectedVault)
    }

    private func openVault(_ vault: VaultRecord) {
        guard canSwitchVault else { return }
        onVaultSelected(vault)
    }
}
