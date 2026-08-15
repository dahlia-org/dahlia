import Foundation
import Observation

/// 初回起動と設定画面で共有する保管庫の管理状態。
@MainActor
@Observable
final class VaultManagementModel {
    static let defaultVaultURL = URL.documentsDirectory
        .appending(path: "Dahlia", directoryHint: .isDirectory)
    private static let defaultVaultName = "Default"

    private(set) var vaults: [VaultRecord] = []
    private(set) var errorMessage = ""
    private(set) var isLoading = false
    private(set) var isRemovingVault = false
    private(set) var isRenamingVault = false
    var isShowingError = false

    private var appDatabase: AppDatabaseManager?
    private var hasLoadedVaults = false
    private var repository: MeetingRepository?

    func configure(appDatabase: AppDatabaseManager?) async {
        guard self.appDatabase !== appDatabase || !hasLoadedVaults else { return }
        self.appDatabase = appDatabase
        hasLoadedVaults = false
        repository = appDatabase.map { MeetingRepository(dbQueue: $0.dbQueue) }
        await loadVaults()
    }

    func loadVaults() async {
        guard let repository else {
            vaults = []
            hasLoadedVaults = false
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            vaults = try await repository.fetchAllVaultsAsync()
            hasLoadedVaults = true
        } catch {
            hasLoadedVaults = false
            guard !Task.isCancelled else { return }
            presentError(L10n.vaultLoadFailed, error: error, source: "loadVaults")
        }
    }

    func resolveStartupVault(
        appDatabase: AppDatabaseManager,
        defaultVaultURL vaultURL: URL = defaultVaultURL
    ) async -> (vault: VaultRecord, isNewlyCreated: Bool)? {
        await configure(appDatabase: appDatabase)
        guard hasLoadedVaults, let repository else { return nil }

        if let lastOpenedVault = vaults.first(where: { $0.lastOpenedAt != .distantPast }) {
            return (lastOpenedVault, false)
        }
        guard vaults.isEmpty else { return nil }

        do {
            try await Self.createDirectory(at: vaultURL)
            let now = Date.now
            let vault = VaultRecord(
                id: .v7(),
                path: Self.normalizedFileURL(vaultURL).path,
                name: Self.defaultVaultName,
                createdAt: now,
                lastOpenedAt: now
            )
            try await repository.insertVaultAsync(vault)
            vaults = [vault]
            return (vault, true)
        } catch {
            guard !Task.isCancelled else { return nil }
            presentError(L10n.vaultAddFailed, error: error, source: "resolveStartupVault.create")
            return nil
        }
    }

    func registerVault(at url: URL, markAsOpened: Bool = true) async -> VaultRecord? {
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
            lastOpenedAt: markAsOpened ? now : .distantPast
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

    func removeVault(_ vault: VaultRecord, currentVaultId: UUID?) async -> Bool {
        guard vault.id != currentVaultId else { return false }
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

    func renameVault(_ vault: VaultRecord, to proposedName: String) async -> VaultRecord? {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard name != vault.name else { return vault }
        guard !isRenamingVault else { return nil }
        guard let repository else {
            presentError(L10n.vaultRenameFailed, source: "renameVault")
            return nil
        }

        isRenamingVault = true
        defer { isRenamingVault = false }
        do {
            guard let renamedVault = try await repository.updateVaultName(id: vault.id, name: name) else {
                presentError(L10n.vaultRenameFailed, source: "renameVault")
                return nil
            }
            if let index = vaults.firstIndex(where: { $0.id == vault.id }) {
                vaults[index] = renamedVault
            }
            return renamedVault
        } catch {
            presentError(L10n.vaultRenameFailed, error: error, source: "renameVault")
            return nil
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

    @concurrent
    private nonisolated static func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
