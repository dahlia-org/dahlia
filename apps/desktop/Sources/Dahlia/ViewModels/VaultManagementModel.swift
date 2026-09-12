import DahliaServerAPI
import Foundation
import GRDB
import Observation

struct PendingVaultServerAdoption: Identifiable {
    let vault: VaultRecord
    let connection: DahliaAccountConnection
    let serverVaults: [CloudVaultRecord]
    let organizations: [Components.Schemas.Organization]

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
    private let organizationFetcher: ((DahliaAccountConnectionRecord) async throws -> [Components.Schemas.Organization])?
    private var syncObservation: AnyDatabaseCancellable?

    init(
        cloudVaultFetcher: CloudVaultFetcher? = nil,
        organizationFetcher: ((DahliaAccountConnectionRecord) async throws -> [Components.Schemas.Organization])? = nil
    ) {
        self.cloudVaultFetcher = cloudVaultFetcher
        self.organizationFetcher = organizationFetcher
    }

    func configure(appDatabase: AppDatabaseManager?) async {
        if self.appDatabase === appDatabase, hasLoadedVaults {
            await loadVaults()
            return
        }
        self.appDatabase = appDatabase
        hasLoadedVaults = false
        repository = appDatabase.map { MeetingRepository(dbQueue: $0.dbQueue) }
        syncObservation?.cancel()
        if let dbQueue = appDatabase?.dbQueue {
            syncObservation = ValueObservation.tracking { db in
                try (
                    VaultRecord.order(Column("lastOpenedAt").desc).fetchAll(db),
                    UUID.fetchSet(db, sql: "SELECT DISTINCT vaultId FROM sync_transactions WHERE blockedReason IS NOT NULL"),
                    UUID.fetchSet(db, sql: "SELECT DISTINCT vaultId FROM sync_transactions WHERE blockedReason = 'conflict'"),
                    UUID.fetchSet(db, sql: "SELECT DISTINCT vaultId FROM sync_transactions WHERE blockedReason = 'validation'")
                )
            }.start(in: dbQueue, onError: { _ in }, onChange: { [weak self] values in
                Task { @MainActor in
                    guard let self, self.appDatabase?.dbQueue === dbQueue else { return }
                    self.vaults = values.0
                    self.blockedSyncVaultIDs = values.1
                    self.conflictedSyncVaultIDs = values.2
                    self.validationBlockedSyncVaultIDs = values.3
                }
            })
        }
        await loadVaults()
    }

    func loadVaults() async {
        guard let repository else {
            vaults = []
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

    private func fetchCloudVaults(from connection: DahliaAccountConnectionRecord) async throws -> [CloudVaultRecord] {
        if let cloudVaultFetcher {
            return try await cloudVaultFetcher(connection)
        }
        let token = try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(connectionID: connection.id)
        return try await CloudVaultDiscovery.fetch(connection: connection, token: token)
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
        guard vault.accountConnectionId == nil else { return false }
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

    func renameVault(_ vault: VaultRecord, to proposedName: String, appearance: ProjectAppearance? = nil) async -> VaultRecord? {
        guard vault.allowsVaultManagement else { return nil }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard name != vault.name || (appearance != nil && appearance != vault.appearance) else { return vault }
        guard !isRenamingVault else { return nil }
        guard let repository else {
            presentError(L10n.vaultRenameFailed, source: "renameVault")
            return nil
        }

        isRenamingVault = true
        defer { isRenamingVault = false }
        do {
            guard let renamedVault = try await repository.updateVaultName(id: vault.id, name: name, appearance: appearance) else {
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
            let serverVaults = try await fetchCloudVaults(from: connection.record)
            let organizations = try await fetchOrganizations(connection.record)
            if let repository {
                _ = try await MeetingRepository.registerDiscoveredCloudVaults(
                    serverVaults,
                    connection: connection.record,
                    dbQueue: repository.dbQueue
                )
            }
            pendingServerAdoption = PendingVaultServerAdoption(
                vault: vault,
                connection: connection,
                serverVaults: serverVaults,
                organizations: organizations
            )
        } catch is CancellationError {
            return
        } catch {
            presentError(L10n.vaultOperationFailed, error: error, source: "requestServerAdoption")
        }
    }

    private func fetchOrganizations(_ connection: DahliaAccountConnectionRecord) async throws -> [Components.Schemas.Organization] {
        if let organizationFetcher { return try await organizationFetcher(connection) }
        return try await CloudVaultDiscovery.organizations(connection: connection, api: SyncAPIClient(session: .shared))
    }

    func reloadServerAdoption() async {
        guard let pending = pendingServerAdoption else { return }
        await requestServerAdoption(for: pending.vault, connection: pending.connection)
    }

    func createAdoptionOrganization(name: String) async {
        guard let pending = pendingServerAdoption, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await CloudVaultDiscovery.createOrganization(name: name, connection: pending.connection.record, api: SyncAPIClient(session: .shared))
            await reloadServerAdoption()
        } catch { presentError(L10n.vaultOperationFailed, error: error, source: "createAdoptionOrganization") }
    }

    func confirmServerAdoption(
        _ pending: PendingVaultServerAdoption, destinationId: UUID?, organizationId: UUID?
    ) async -> VaultRecord? {
        guard updatingVaultAccountID == nil, let repository else { return nil }
        updatingVaultAccountID = pending.vault.id
        defer { updatingVaultAccountID = nil }
        do {
            let api = SyncAPIClient(session: .shared)
            let connection = pending.connection.record
            let backup = BackupService(dbQueue: repository.dbQueue)
            let currentVaults = try await fetchCloudVaults(from: connection)
            let updated: VaultRecord
            if let destinationId, destinationId != pending.vault.id {
                guard let destination = currentVaults.first(where: { $0.vaultId == destinationId }) else { throw LocalVaultImportError.unavailable }
                updated = try await LocalVaultImport.run(
                    sourceId: pending.vault.id,
                    destination: destination,
                    dbQueue: repository.dbQueue,
                    backup: backup,
                    api: api
                )
            } else {
                guard let organizationId,
                      try await fetchOrganizations(connection)
                      .contains(where: { $0.id == organizationId.uuidString.lowercased() && $0.kind == .team }) else {
                    throw LocalVaultImportError.unavailable
                }
                let fence = try await repository.dbQueue.read { db in
                    guard try DahliaAccountConnectionRecord.fetchOne(db, key: connection.id) == connection,
                          let source = try VaultRecord.fetchOne(db, key: pending.vault.id), source.accountConnectionId == nil,
                          try !RecordingSessionRecord.hasActiveRecording(vaultId: source.id, in: db),
                          try !SyncTransactionQueue.hasPending(vaultId: source.id, in: db) else { throw LocalVaultImportError.unavailable }
                    return db.totalChangesCount
                }
                _ = try await backup.createGeneration(vaultIds: [pending.vault.id])
                if !currentVaults.contains(where: { $0.vaultId == pending.vault.id }) {
                    try await CloudVaultDiscovery.createVault(pending.vault, organizationId: organizationId, connection: connection, api: api)
                }
                guard let serverVault = try await fetchCloudVaults(from: connection).first(where: { $0.vaultId == pending.vault.id }),
                      serverVault.organizationId == organizationId, serverVault.role == "admin",
                      let origin = URL(string: connection.origin) else { throw LocalVaultImportError.unavailable }
                let snapshot = try await SyncWorker(dbQueue: repository.dbQueue, apiClient: api)
                    .importSnapshot(vaultId: serverVault.vaultId, connectionId: connection.id, origin: origin)
                guard snapshot.projects.isEmpty, snapshot.meetings.isEmpty, snapshot.files.isEmpty else { throw LocalVaultImportError.collision }
                guard try await fetchCloudVaults(from: connection).contains(where: {
                    $0.vaultId == serverVault.vaultId && $0.organizationId == organizationId && $0.role == "admin"
                }) else { throw LocalVaultImportError.unavailable }
                guard let adopted = try await repository.adoptVaultForServerSync(
                    id: pending.vault.id,
                    connectionID: connection.id,
                    serverVault: serverVault,
                    expectedChanges: fence
                ) else {
                    throw LocalVaultImportError.changed
                }
                updated = adopted
            }
            pendingServerAdoption = nil
            await loadVaults()
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
