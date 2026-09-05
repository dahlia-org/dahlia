import Foundation
import Observation

struct PendingVaultServerAdoption: Identifiable {
    let vault: VaultRecord
    let connection: DahliaAccountConnection
    let serverVault: CloudVaultRecord?

    var id: UUID { vault.id }
}

/// 初回起動と設定画面で共有する保管庫の管理状態。
@MainActor
@Observable
final class VaultManagementModel {
    typealias CloudVaultFetcher = (DahliaAccountConnectionRecord) async throws -> [CloudVaultRecord]

    static let defaultVaultURL = URL.documentsDirectory
        .appending(path: "Dahlia", directoryHint: .isDirectory)

    private(set) var vaults: [VaultRecord] = []
    private(set) var cloudVaults: [CloudVaultRecord] = []
    private(set) var blockedSyncVaultIDs: Set<UUID> = []
    private(set) var conflictedSyncVaultIDs: Set<UUID> = []
    private(set) var validationBlockedSyncVaultIDs: Set<UUID> = []
    private(set) var pendingServerAdoption: PendingVaultServerAdoption?
    private(set) var errorMessage = ""
    private(set) var isLoading = false
    private(set) var isRemovingVault = false
    private(set) var isRenamingVault = false
    private(set) var updatingVaultAccountID: UUID?
    var isShowingError = false

    private var appDatabase: AppDatabaseManager?
    private(set) var hasLoadedVaults = false
    private var repository: MeetingRepository?
    private let cloudVaultFetcher: CloudVaultFetcher?

    init(cloudVaultFetcher: CloudVaultFetcher? = nil) {
        self.cloudVaultFetcher = cloudVaultFetcher
    }

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
            blockedSyncVaultIDs = []
            conflictedSyncVaultIDs = []
            validationBlockedSyncVaultIDs = []
            hasLoadedVaults = false
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            vaults = try await repository.fetchAllVaultsAsync()
            let localVaultIDs = Set(vaults.map(\.id))
            cloudVaults = try await fetchCloudVaults(repository: repository)
                .filter { !localVaultIDs.contains($0.vaultId) }
            blockedSyncVaultIDs = try await repository.blockedSyncVaultIDs()
            conflictedSyncVaultIDs = try await repository.conflictedSyncVaultIDs()
            validationBlockedSyncVaultIDs = try await repository.validationBlockedSyncVaultIDs()
            hasLoadedVaults = true
        } catch {
            hasLoadedVaults = false
            guard !Task.isCancelled else { return }
            presentError(L10n.vaultLoadFailed, error: error, source: "loadVaults")
        }
    }

    private func fetchCloudVaults(repository: MeetingRepository) async throws -> [CloudVaultRecord] {
        var result: [CloudVaultRecord] = []
        for connection in try await repository.fetchDahliaAccountConnections() {
            do {
                result += try await fetchCloudVaults(from: connection)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return result.sorted { ($0.name, $0.vaultId.uuidString) < ($1.name, $1.vaultId.uuidString) }
    }

    private func fetchCloudVaults(from connection: DahliaAccountConnectionRecord) async throws -> [CloudVaultRecord] {
        if let cloudVaultFetcher {
            return try await cloudVaultFetcher(connection)
        }
        let token = try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(connectionID: connection.id)
        return try await CloudVaultDiscovery.fetch(connection: connection, token: token)
    }

    func registerCloudVault(_ cloudVault: CloudVaultRecord) async -> VaultRecord? {
        guard let repository else { return nil }
        var vault = VaultRecord(
            id: cloudVault.vaultId,
            path: nil,
            name: cloudVault.name,
            createdAt: cloudVault.createdAt,
            lastOpenedAt: .distantPast
        )
        vault.accountConnectionId = cloudVault.connectionId
        vault.syncConfirmedConnectionId = cloudVault.connectionId
        vault.syncRole = cloudVault.role
        do {
            try await repository.insertCloudVaultAsync(vault, revision: cloudVault.revision)
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

    func createVault(named proposedName: String) async -> VaultRecord? {
        guard let repository else {
            presentError(L10n.vaultAddFailed, source: "createVault")
            return nil
        }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let now = Date.now
        var vault = VaultRecord(
            id: .v7(),
            path: nil,
            name: name,
            createdAt: now,
            lastOpenedAt: .distantPast
        )
        VaultAISettingsModel.shared.snapshot(for: vault.id).applyAISettings(to: &vault)
        do {
            try await repository.insertVaultAsync(vault)
            await loadVaults()
            return vault
        } catch {
            presentError(L10n.vaultAddFailed, error: error, source: "createVault")
            return nil
        }
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
        if let existingVault = vaults.first(where: {
            $0.url.map(Self.normalizedFileURL) == normalizedURL
        }) {
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
        VaultAISettingsModel.shared.snapshot(for: vault.id).applyAISettings(to: &vault)

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

    func setExportFolder(for vault: VaultRecord, to url: URL?) async -> VaultRecord? {
        guard let repository else { return nil }
        let normalizedURL = url.map(Self.normalizedFileURL)
        if let normalizedURL,
           vaults.contains(where: { $0.id != vault.id && $0.url.map(Self.normalizedFileURL) == normalizedURL }) {
            return nil
        }
        do {
            if let normalizedURL {
                try await Self.createDirectory(at: normalizedURL)
            }
            guard let updated = try await repository.updateVaultPath(id: vault.id, path: normalizedURL?.path) else {
                return nil
            }
            if let index = vaults.firstIndex(where: { $0.id == vault.id }) {
                vaults[index] = updated
            }
            return updated
        } catch {
            presentError(L10n.vaultFolderSelectionFailed, error: error, source: "setExportFolder")
            return nil
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
        guard vault.allowsCanonicalEdits else { return nil }
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

    func requestServerAdoption(for vault: VaultRecord, connection: DahliaAccountConnection) async {
        guard updatingVaultAccountID == nil,
              vault.accountConnectionId == nil,
              connection.isSignedIn,
              connection.supportsVaultSync
        else { return }
        updatingVaultAccountID = vault.id
        defer { updatingVaultAccountID = nil }
        do {
            let serverVault = try await fetchCloudVaults(from: connection.record)
                .first(where: { $0.vaultId == vault.id })
            pendingServerAdoption = PendingVaultServerAdoption(
                vault: vault,
                connection: connection,
                serverVault: serverVault
            )
        } catch is CancellationError {
            return
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "requestServerAdoption")
        }
    }

    func confirmServerAdoption(_ pendingServerAdoption: PendingVaultServerAdoption) async -> VaultRecord? {
        guard updatingVaultAccountID == nil, let repository else { return nil }
        self.pendingServerAdoption = nil
        updatingVaultAccountID = pendingServerAdoption.vault.id
        defer { updatingVaultAccountID = nil }
        do {
            let currentServerVault = try await fetchCloudVaults(from: pendingServerAdoption.connection.record)
                .first(where: { $0.vaultId == pendingServerAdoption.vault.id })
            guard pendingServerAdoption.serverVault == nil || currentServerVault != nil else {
                presentError(L10n.vaultOperationFailed, source: "confirmServerAdoption.revoked")
                return nil
            }
            if (pendingServerAdoption.serverVault?.role, pendingServerAdoption.serverVault != nil)
                != (currentServerVault?.role, currentServerVault != nil) {
                self.pendingServerAdoption = PendingVaultServerAdoption(
                    vault: pendingServerAdoption.vault,
                    connection: pendingServerAdoption.connection,
                    serverVault: currentServerVault
                )
                return nil
            }
            guard let updated = try await repository.adoptVaultForServerSync(
                id: pendingServerAdoption.vault.id,
                connectionID: pendingServerAdoption.connection.id,
                serverVault: currentServerVault
            ) else { return nil }
            if let index = vaults.firstIndex(where: { $0.id == updated.id }) { vaults[index] = updated }
            cloudVaults.removeAll(where: { $0.vaultId == updated.id })
            return updated
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "confirmServerAdoption")
            return nil
        }
    }

    func cancelServerAdoption() {
        pendingServerAdoption = nil
    }

    func acceptServerSyncVersion(for vault: VaultRecord) async {
        guard let repository else { return }
        do {
            try await repository.acceptServerSyncVersion(vaultId: vault.id)
            blockedSyncVaultIDs.remove(vault.id)
            conflictedSyncVaultIDs.remove(vault.id)
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "acceptServerSyncVersion")
        }
    }

    func reapplyLocalSyncVersion(for vault: VaultRecord) async {
        guard let repository else { return }
        do {
            try await repository.reapplyLocalSyncVersion(vaultId: vault.id)
            blockedSyncVaultIDs.remove(vault.id)
            conflictedSyncVaultIDs.remove(vault.id)
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "reapplyLocalSyncVersion")
        }
    }

    func discardInvalidSyncTransaction(for vault: VaultRecord) async {
        guard let repository else { return }
        do {
            try await repository.discardInvalidSyncTransaction(vaultId: vault.id)
            blockedSyncVaultIDs.remove(vault.id)
            validationBlockedSyncVaultIDs.remove(vault.id)
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "discardInvalidSyncTransaction")
        }
    }

    func retryInvalidSyncTransaction(for vault: VaultRecord) async {
        guard let repository else { return }
        do {
            try await repository.retryInvalidSyncTransaction(vaultId: vault.id)
            blockedSyncVaultIDs.remove(vault.id)
            validationBlockedSyncVaultIDs.remove(vault.id)
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "retryInvalidSyncTransaction")
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
