import DahliaRuntimeSupport
import Foundation
import GRDB
import Observation

struct BackupRestoreSelection: Identifiable {
    let workspace: BackupWorkspace
    var mode: WorkspaceBackupRestoreRequest.Mode?
    var name: String
    var id: UUID { workspace.id }
}

@Observable
@MainActor
final class BackupSettingsViewModel {
    private(set) var generations: [BackupGeneration] = []
    private(set) var workspaces: [WorkspaceRecord] = []
    var selectedWorkspaceIds: Set<UUID> = []
    var restoreSelections: [BackupRestoreSelection] = []
    private(set) var allPreflightItems: [BackupPreflightItem] = []
    var preflightItems: [BackupPreflightItem] { allPreflightItems.filter { selectedWorkspaceIds.contains($0.workspaceId) } }
    private(set) var hasWorkInProgress = false

    func canOverwrite(workspaceId: UUID) -> Bool {
        workspaces.contains { $0.id == workspaceId && $0.accountConnectionId == nil && $0.syncRole == nil && $0.syncConfirmedConnectionId == nil }
            && !allPreflightItems.contains { $0.workspaceId == workspaceId }
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
            case let .completed(results):
                let successes = results.filter { $0.error == nil }.map(\.localizedMessage)
                let failures = results.filter { $0.error != nil }.map(\.localizedMessage)
                statusMessage = successes.isEmpty ? nil : successes.joined(separator: "\n")
                errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
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
            workspaces = try await service.listWorkspaces()
            selectedWorkspaceIds.formIntersection(workspaces.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createBackup() async {
        guard !selectedWorkspaceIds.isEmpty else { return }
        await perform {
            _ = try await requireService().createGeneration(workspaceIds: selectedWorkspaceIds)
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
                    expectedWorkspaceId: item.workspaceId
                )
            guard discarded else { throw BackupServiceError.invalidBackup }
            statusMessage = L10n.unprocessedRecordingDiscarded
        }
    }

    func beginRestore(_ metadata: BackupMetadata) {
        restoreSelections = metadata.workspaces.map { BackupRestoreSelection(workspace: $0, mode: nil, name: L10n.restoredWorkspaceName($0.name)) }
        errorMessage = nil
    }

    var canRestore: Bool {
        !isBusy && !hasWorkInProgress
            && restoreSelections.contains { $0.mode != nil }
            && restoreSelections.allSatisfy { selection in
                switch selection.mode {
                case .none: true
                case .overwrite: canOverwrite(workspaceId: selection.id)
                case .newWorkspace: selection.name.nilIfBlank != nil
                }
            }
    }

    func prepareRestore(_ generation: BackupGeneration) async -> Bool {
        guard canRestore else { return false }
        let requests = restoreSelections.compactMap { selection -> WorkspaceBackupRestoreRequest? in
            guard let mode = selection.mode else { return nil }
            return WorkspaceBackupRestoreRequest(
                sourceWorkspaceId: selection.id,
                targetWorkspaceId: mode == .overwrite ? selection.id : .v7(),
                mode: mode, name: mode == .overwrite ? selection.workspace.name : selection.name
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
