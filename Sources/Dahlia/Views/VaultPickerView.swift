import Combine
import SwiftUI

/// 保管庫の登録・選択・登録解除を行う画面。
struct VaultPickerView: View {
    let appDatabase: AppDatabaseManager?
    let onVaultSelected: (VaultRecord) -> Void

    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var settings = AppSettings.shared
    @State private var vaults: [VaultRecord] = []
    @State private var selectedVaultId: UUID?
    @State private var isShowingFolderPicker = false
    @State private var isShowingError = false
    @State private var errorMessage = ""

    private static let defaultVaultURL = URL.documentsDirectory
        .appending(path: "Meetings", directoryHint: .isDirectory)

    private var repository: MeetingRepository? {
        appDatabase.map { MeetingRepository(dbQueue: $0.dbQueue) }
    }

    private var selectedVault: VaultRecord? {
        guard let selectedVaultId else { return nil }
        return vaults.first(where: { $0.id == selectedVaultId })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            VaultSidebarView(
                vaults: vaults,
                selectedVaultId: $selectedVaultId,
                currentVaultId: settings.currentVault?.id,
                onAdd: showFolderPicker,
                onRemove: removeVault
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            VaultDetailView(
                vault: selectedVault,
                hasRegisteredVaults: !vaults.isEmpty,
                isCurrentVault: selectedVault?.id == settings.currentVault?.id,
                onOpen: openSelectedVault,
                onAdd: showFolderPicker
            )
        }
        .frame(minWidth: 720, minHeight: 460)
        .task(id: appDatabase != nil) {
            loadVaults()
        }
        .fileImporter(
            isPresented: $isShowingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderImport
        )
        .fileDialogDefaultDirectory(Self.defaultVaultURL)
        .alert(L10n.vaultOperationFailed, isPresented: $isShowingError) {} message: {
            Text(errorMessage)
        }
    }

    private func showFolderPicker() {
        isShowingFolderPicker = true
    }

    private func handleFolderImport(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            registerVault(url: url)
        case let .failure(error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            presentError(L10n.vaultFolderSelectionFailed, error: error, source: "folderImport")
        }
    }

    private func loadVaults(preferredSelection: UUID? = nil) {
        guard let repository else {
            vaults = []
            selectedVaultId = nil
            return
        }

        do {
            let loadedVaults = try repository.fetchAllVaults()
            let preferredIds = [preferredSelection, selectedVaultId, settings.currentVault?.id].compactMap(\.self)
            vaults = loadedVaults
            selectedVaultId = preferredIds.first(where: { id in
                loadedVaults.contains(where: { $0.id == id })
            }) ?? loadedVaults.first?.id
        } catch {
            presentError(L10n.vaultLoadFailed, error: error, source: "loadVaults")
        }
    }

    private func registerVault(url: URL) {
        guard let repository else { return }

        let normalizedURL = url.standardizedFileURL
        if let existingVault = vaults.first(where: { $0.url.standardizedFileURL == normalizedURL }) {
            selectedVaultId = existingVault.id
            openVault(existingVault)
            return
        }

        let now = Date.now
        let vault = VaultRecord(
            id: .v7(),
            path: normalizedURL.path,
            name: normalizedURL.lastPathComponent,
            createdAt: now,
            lastOpenedAt: now
        )

        do {
            try repository.insertVault(vault)
            loadVaults(preferredSelection: vault.id)
            openVault(vault)
        } catch {
            presentError(L10n.vaultAddFailed, error: error, source: "registerVault")
        }
    }

    private func removeVault(_ vault: VaultRecord) {
        guard let repository else { return }
        Task {
            do {
                try await repository.deleteVaultSafely(id: vault.id)
                vaults.removeAll(where: { $0.id == vault.id })
                if selectedVaultId == vault.id {
                    selectedVaultId = vaults.first?.id
                }
            } catch {
                presentError(L10n.vaultRemoveFailed, error: error, source: "removeVault")
            }
        }
    }

    private func openSelectedVault() {
        guard let selectedVault else { return }
        openVault(selectedVault)
    }

    private func openVault(_ vault: VaultRecord) {
        onVaultSelected(vault)
        openWindow(id: WindowID.main)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentError(_ message: String, error: any Error, source: String) {
        errorMessage = message
        isShowingError = true
        ErrorReportingService.capture(error, context: ["source": source])
    }
}
