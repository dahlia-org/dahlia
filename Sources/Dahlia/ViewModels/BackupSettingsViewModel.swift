import Foundation
import GRDB
import Observation

@Observable
@MainActor
final class BackupSettingsViewModel {
    private(set) var generations: [BackupGeneration] = []
    private(set) var preflightItems: [BackupPreflightItem] = []
    private(set) var isBusy = false
    var statusMessage: String?
    var errorMessage: String?

    private let dbQueue: DatabaseQueue?
    private let service: BackupService?

    init(dbQueue: DatabaseQueue?) {
        self.dbQueue = dbQueue
        service = dbQueue.map { BackupService(dbQueue: $0) }
    }

    func refresh() async {
        guard let service else { return }
        if statusMessage == nil {
            switch AppDelegate.backupRestoreOutcome {
            case .none:
                break
            case let .restored(metadata):
                statusMessage = L10n.backupRestored(schemaVersion: metadata.schemaVersion)
            case let .failed(message):
                errorMessage = L10n.backupRestoreFailed(message)
            }
        }
        do {
            async let generations = service.listGenerations()
            async let preflightItems = service.preflightItems()
            self.generations = try await generations
            self.preflightItems = try await preflightItems
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createBackup() async {
        await perform {
            _ = try await requireService().createGeneration()
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
                .discardUnprocessedBatchSessionSafely(id: item.sessionId)
            guard discarded else { throw BackupServiceError.invalidBackup }
            statusMessage = L10n.unprocessedRecordingDiscarded
        }
    }

    func prepareRestore(_ generation: BackupGeneration) async -> Bool {
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
            _ = try await requireService().prepareRestore(from: generation)
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
