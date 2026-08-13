import Foundation
import Observation

/// 初回起動と設定画面で共有する保管庫の登録・登録解除状態。
@MainActor
@Observable
final class VaultManagementModel {
    static let defaultVaultURL = URL.documentsDirectory
        .appending(path: "Meetings", directoryHint: .isDirectory)

    private(set) var vaults: [VaultRecord] = []
    private(set) var errorMessage = ""
    private(set) var isLoading = false
    private(set) var isRemovingVault = false
    var isShowingError = false

    private var appDatabase: AppDatabaseManager?
    private var repository: MeetingRepository?

    func configure(appDatabase: AppDatabaseManager?) async {
        guard self.appDatabase !== appDatabase else { return }
        self.appDatabase = appDatabase
        repository = appDatabase.map { MeetingRepository(dbQueue: $0.dbQueue) }
        await loadVaults()
    }

    func loadVaults() async {
        guard let repository else {
            vaults = []
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            vaults = try await repository.fetchAllVaultsAsync()
        } catch {
            presentError(L10n.vaultLoadFailed, error: error, source: "loadVaults")
        }
    }

    func registerVault(at url: URL) async -> VaultRecord? {
        guard let repository else {
            presentError(L10n.vaultAddFailed, source: "registerVault")
            return nil
        }

        let normalizedURL = Self.normalizedFileURL(url)
        if let existingVault = vaults.first(where: { Self.normalizedFileURL($0.url) == normalizedURL }) {
            return existingVault
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
            try await repository.insertVaultAsync(vault)
            await loadVaults()
            return vault
        } catch {
            presentError(L10n.vaultAddFailed, error: error, source: "registerVault")
            return nil
        }
    }

    func removeVault(_ vault: VaultRecord) async -> Bool {
        guard !isRemovingVault else { return false }
        guard let repository else {
            presentError(L10n.vaultRemoveFailed, source: "removeVault")
            return false
        }

        isRemovingVault = true
        defer { isRemovingVault = false }
        do {
            try await repository.deleteVaultSafely(id: vault.id)
            vaults.removeAll(where: { $0.id == vault.id })
            return true
        } catch {
            presentError(L10n.vaultRemoveFailed, error: error, source: "removeVault")
            return false
        }
    }

    func presentFolderSelectionError(_ error: any Error) {
        presentError(L10n.vaultFolderSelectionFailed, error: error, source: "folderImport")
    }

    private static func normalizedFileURL(_ url: URL) -> URL {
        URL(
            filePath: (url.path as NSString).standardizingPath,
            directoryHint: .isDirectory
        )
    }

    private func presentError(
        _ message: String,
        error: (any Error)? = nil,
        source: String
    ) {
        errorMessage = message
        isShowingError = true
        if let error {
            ErrorReportingService.capture(error, context: ["source": source])
        }
    }
}
