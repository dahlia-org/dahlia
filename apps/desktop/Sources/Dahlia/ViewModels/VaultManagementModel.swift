import Foundation
import Observation

/// 初回起動と設定画面で共有する保管庫の管理状態。
@MainActor
@Observable
final class VaultManagementModel {
    static let defaultVaultURL = URL.documentsDirectory
        .appending(path: "Dahlia", directoryHint: .isDirectory)

    private(set) var vaults: [VaultRecord] = []
    private(set) var cloudVaults: [CloudVaultRecord] = []
    private(set) var pendingMeetingDeletionCounts: [UUID: Int] = [:]
    private(set) var errorMessage = ""
    private(set) var isLoading = false
    private(set) var isRemovingVault = false
    private(set) var isRenamingVault = false
    private(set) var updatingVaultAccountID: UUID?
    private(set) var updatingVaultSyncID: UUID?
    var isShowingError = false

    private var appDatabase: AppDatabaseManager?
    private(set) var hasLoadedVaults = false
    private var repository: MeetingRepository?

    func configure(appDatabase: AppDatabaseManager?) async {
        if self.appDatabase === appDatabase, hasLoadedVaults {
            await loadVaults()
            return
        }
        self.appDatabase = appDatabase
        hasLoadedVaults = false
        repository = appDatabase.map { MeetingRepository(dbQueue: $0.dbQueue) }
        await loadVaults()
    }

    func loadVaults() async {
        guard let repository else {
            vaults = []
            cloudVaults = []
            hasLoadedVaults = false
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            vaults = try await repository.fetchAllVaultsAsync()
            let localVaultIDs = Set(vaults.map(\.id))
            cloudVaults = try await repository.fetchCloudVaultsAsync().filter { !localVaultIDs.contains($0.vaultId) }
            pendingMeetingDeletionCounts = try await repository.pendingMeetingDeletionCounts()
            hasLoadedVaults = true
        } catch {
            hasLoadedVaults = false
            guard !Task.isCancelled else { return }
            presentError(L10n.vaultLoadFailed, error: error, source: "loadVaults")
        }
    }

    func registerCloudVault(_ cloudVault: CloudVaultRecord, at url: URL) async -> VaultRecord? {
        guard let repository else { return nil }
        let normalizedURL = Self.normalizedFileURL(url)
        guard !vaults.contains(where: { Self.normalizedFileURL($0.url) == normalizedURL }) else { return nil }
        var vault = VaultRecord(
            id: cloudVault.vaultId,
            path: normalizedURL.path,
            name: cloudVault.name,
            createdAt: cloudVault.createdAt,
            lastOpenedAt: .distantPast
        )
        vault.accountConnectionId = cloudVault.connectionId
        vault.syncConfirmedConnectionId = cloudVault.connectionId
        vault.syncEnabled = true
        vault.serverRevision = cloudVault.revision
        vault.syncBootstrapPending = true
        do {
            try await repository.insertVaultAsync(vault)
            await loadVaults()
            return vault
        } catch {
            presentError(L10n.vaultAddFailed, error: error, source: "registerCloudVault")
            return nil
        }
    }

    func resolveExistingStartupVault(appDatabase: AppDatabaseManager) async -> VaultRecord? {
        await configure(appDatabase: appDatabase)
        guard hasLoadedVaults else { return nil }
        return vaults.first(where: { $0.lastOpenedAt != .distantPast })
    }

    func createVault(at url: URL) async -> VaultRecord? {
        do {
            try await Self.createDirectory(at: url)
        } catch {
            guard !Task.isCancelled else { return nil }
            presentError(L10n.vaultAddFailed, error: error, source: "createVault.directory")
            return nil
        }
        return await registerVault(at: url, markAsOpened: false)
    }

    func registerVault(
        at url: URL,
        markAsOpened: Bool = true
    ) async -> VaultRecord? {
        guard let repository else {
            presentError(L10n.vaultAddFailed, source: "registerVault")
            return nil
        }

        let normalizedURL = Self.normalizedFileURL(url)
        if let existingVault = vaults.first(where: { Self.normalizedFileURL($0.url) == normalizedURL }) {
            return existingVault
        }

        let now = Date.now
        var vault = VaultRecord(
            id: .v7(),
            path: normalizedURL.path,
            name: normalizedURL.lastPathComponent,
            createdAt: now,
            lastOpenedAt: markAsOpened ? now : .distantPast
        )
        VaultAISettingsModel.shared.snapshot(for: vault.id).apply(to: &vault)

        do {
            try await repository.insertVaultAsync(vault)
            await loadVaults()
            return vault
        } catch {
            presentError(L10n.vaultAddFailed, error: error, source: "registerVault")
            return nil
        }
    }

    func markVaultOpened(_ vault: VaultRecord) async -> Bool {
        guard let repository else {
            presentError(L10n.vaultOperationFailed, source: "markVaultOpened")
            return false
        }

        do {
            guard let updatedVault = try await repository.updateVaultLastOpened(id: vault.id) else {
                presentError(L10n.vaultOperationFailed, source: "markVaultOpened")
                return false
            }
            if let index = vaults.firstIndex(where: { $0.id == vault.id }) {
                vaults[index] = updatedVault
            }
            return true
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "markVaultOpened")
            return false
        }
    }

    func removeVault(_ vault: VaultRecord, currentVaultId: UUID?) async -> Bool {
        guard vault.id != currentVaultId else { return false }
        guard !vault.requiresServerDeletionBeforeRemoval else { return false }
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

    func updateAccountConnection(for vault: VaultRecord, connectionID: UUID?) async -> VaultRecord? {
        guard vault.accountConnectionId != connectionID else { return vault }
        guard updatingVaultAccountID == nil else { return nil }
        guard let repository else {
            presentError(L10n.vaultOperationFailed, source: "updateAccountConnection")
            return nil
        }

        updatingVaultAccountID = vault.id
        defer { updatingVaultAccountID = nil }
        do {
            guard let updatedVault = try await repository.updateVaultAccountConnection(
                id: vault.id,
                connectionID: connectionID
            ) else {
                presentError(L10n.vaultOperationFailed, source: "updateAccountConnection")
                return nil
            }
            if let index = vaults.firstIndex(where: { $0.id == vault.id }) {
                vaults[index] = updatedVault
            }
            return updatedVault
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "updateAccountConnection")
            return nil
        }
    }

    func updateSync(for vault: VaultRecord, isEnabled: Bool) async -> VaultRecord? {
        guard vault.syncEnabled != isEnabled, updatingVaultSyncID == nil, let repository else { return vault }
        updatingVaultSyncID = vault.id
        defer { updatingVaultSyncID = nil }
        do {
            guard let updated = try await repository.updateVaultSync(id: vault.id, isEnabled: isEnabled) else {
                presentError(L10n.vaultSyncRequiresAccount, source: "updateVaultSync")
                return nil
            }
            if let index = vaults.firstIndex(where: { $0.id == vault.id }) { vaults[index] = updated }
            return updated
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "updateVaultSync")
            return nil
        }
    }

    func acceptServerSyncVersion(for vault: VaultRecord) async {
        guard let repository else { return }
        do {
            try await repository.acceptServerSyncVersion(vaultId: vault.id)
            if let index = vaults.firstIndex(where: { $0.id == vault.id }) {
                vaults[index].syncConflictJSON = nil
                vaults[index].syncBootstrapPending = true
            }
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "acceptServerSyncVersion")
        }
    }

    func reapplyLocalSyncVersion(for vault: VaultRecord) async {
        guard let repository else { return }
        do {
            try await repository.reapplyLocalSyncVersion(vaultId: vault.id)
            if let index = vaults.firstIndex(where: { $0.id == vault.id }) {
                vaults[index].syncConflictJSON = nil
            }
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "reapplyLocalSyncVersion")
        }
    }

    func deleteServerCopy(for vault: VaultRecord) async -> VaultRecord? {
        guard updatingVaultSyncID == nil, let repository else { return nil }
        updatingVaultSyncID = vault.id
        defer { updatingVaultSyncID = nil }
        do {
            guard let updated = try await repository.requestServerVaultDeletion(id: vault.id) else { return nil }
            if let index = vaults.firstIndex(where: { $0.id == vault.id }) { vaults[index] = updated }
            return updated
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "deleteServerCopy")
            return nil
        }
    }

    func approvePendingMeetingDeletions(for vault: VaultRecord) async {
        guard let repository else { return }
        do {
            try await repository.approvePendingMeetingDeletions(vaultId: vault.id)
            pendingMeetingDeletionCounts[vault.id] = nil
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "approvePendingMeetingDeletions")
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
