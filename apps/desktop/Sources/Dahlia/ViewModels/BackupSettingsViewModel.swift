import DahliaRuntimeSupport
import Foundation
import GRDB
import Observation

struct BackupRestoreSelection: Identifiable {
    let vault: BackupVault
    var mode: VaultBackupRestoreRequest.Mode?
    var name: String
    var id: UUID { vault.id }
}

@Observable
@MainActor
final class BackupSettingsViewModel {
    private(set) var generations: [BackupGeneration] = []
    private(set) var vaults: [VaultRecord] = []
    var selectedVaultIds: Set<UUID> = []
    var restoreSelections: [BackupRestoreSelection] = []
    private(set) var allPreflightItems: [BackupPreflightItem] = []
    var preflightItems: [BackupPreflightItem] { allPreflightItems.filter { selectedVaultIds.contains($0.vaultId) } }
    private(set) var hasWorkInProgress = false

    func canOverwrite(vaultId: UUID) -> Bool {
        vaults.contains { $0.id == vaultId && $0.accountConnectionId == nil && $0.syncRole == nil && $0.syncConfirmedConnectionId == nil }
            && !allPreflightItems.contains { $0.vaultId == vaultId }
    }

    private(set) var isBusy = false
    var statusMessage: String?
    var errorMessage: String?

    private let dbQueue: DatabaseQueue?
    private let service: BackupService?

    init(dbQueue: DatabaseQueue?, applicationSupportURL: URL = DahliaApplicationSupport.currentDirectoryURL) {
        self.dbQueue = dbQueue
        service = dbQueue.map { BackupService(dbQueue: $0, applicationSupportURL: applicationSupportURL) }
    }

    func refresh() async {
        guard let service else { return }
        if statusMessage == nil {
            switch AppDelegate.backupRestoreOutcome {
            case .none:
                break
            case .restored:
                statusMessage = L10n.backupRestored
            case let .failed(message):
                errorMessage = L10n.backupRestoreFailed(message)
            }
        }
        do {
            async let generations = service.listGenerations()
            async let preflightItems = service.preflightItems()
            self.generations = try await generations
            self.allPreflightItems = try await preflightItems
            hasWorkInProgress = try await service.hasProcessingAudio() || allPreflightItems.contains(where: \.isWorkInProgress)
            vaults = try await service.listVaults()
            selectedVaultIds.formIntersection(vaults.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createBackup() async {
        guard !selectedVaultIds.isEmpty else { return }
        await perform {
            _ = try await requireService().createGeneration(vaultIds: selectedVaultIds)
            statusMessage = L10n.backupCreated
        }
    }

    func importBackup(from url: URL) async {
        await perform {
            _ = try await requireService().importGeneration(from: url)
            statusMessage = L10n.backupImported
        }
    }

    func exportBackup(_ generation: BackupGeneration, to url: URL) async {
        await perform(refreshAfterward: false) {
            try await requireService().exportGeneration(generation, to: url)
            statusMessage = L10n.backupExported
        }
    }

    func deleteBackup(_ generation: BackupGeneration) async {
        await perform {
            try await requireService().deleteGeneration(generation)
            statusMessage = L10n.backupDeleted
        }
    }

    func discardAudio(_ item: BackupPreflightItem) async {
        guard let dbQueue else { return }
        await perform {
            let discarded = try await MeetingRepository(dbQueue: dbQueue)
                .discardUnprocessedBatchSessionSafely(
                    id: item.sessionId,
                    expectedVaultId: item.vaultId
                )
            guard discarded else { throw BackupServiceError.invalidBackup }
            statusMessage = L10n.unprocessedRecordingDiscarded
        }
    }

    func beginRestore(_ metadata: BackupMetadata) {
        restoreSelections = metadata.vaults.map { BackupRestoreSelection(vault: $0, mode: nil, name: L10n.restoredVaultName($0.name)) }
        errorMessage = nil
    }

    var canRestore: Bool {
        !isBusy && !hasWorkInProgress
            && restoreSelections.contains { $0.mode != nil }
            && restoreSelections.allSatisfy { selection in
                switch selection.mode {
                case .none: true
                case .overwrite: canOverwrite(vaultId: selection.id)
                case .newVault: selection.name.nilIfBlank != nil
                }
            }
    }

    func prepareRestore(_ generation: BackupGeneration) async -> Bool {
        guard canRestore else { return false }
        let requests = restoreSelections.compactMap { selection -> VaultBackupRestoreRequest? in
            guard let mode = selection.mode else { return nil }
            return VaultBackupRestoreRequest(
                sourceVaultId: selection.id,
                targetVaultId: mode == .overwrite ? selection.id : .v7(),
                mode: mode, name: mode == .overwrite ? selection.vault.name : selection.name
            )
        }
        guard AppDelegate.beginBackupRestorePreparation() else {
            errorMessage = BackupServiceError.restoreAlreadyPending.localizedDescription
            return false
        }
        var prepared = false
        defer {
            if !prepared {
                AppDelegate.cancelBackupRestorePreparation()
            }
        }
        await perform(refreshAfterward: false) {
            _ = try await requireService().prepareRestore(from: generation, requests: requests)
            prepared = true
        }
        return prepared
    }

    private func perform(
        refreshAfterward: Bool = true,
        operation: () async throws -> Void
    ) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        defer { isBusy = false }
        do {
            try await operation()
            if refreshAfterward {
                await refresh()
            }
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
        }
    }

    private func requireService() throws -> BackupService {
        guard let service else { throw BackupServiceError.invalidBackup }
        return service
    }
}
