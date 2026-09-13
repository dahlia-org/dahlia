import DahliaServerAPI
import Foundation
import GRDB
import Observation

struct PendingWorkspaceServerAdoption: Identifiable {
    let workspace: WorkspaceRecord
    let connection: DahliaAccountConnection
    let serverWorkspaces: [CloudWorkspaceRecord]
    let organizations: [Components.Schemas.Organization]

    var id: UUID { workspace.id }
}

/// 初回起動と設定画面で共有するワークスペースの管理状態。
@MainActor
@Observable
final class WorkspaceManagementModel {
    typealias CloudWorkspaceFetcher = (DahliaAccountConnectionRecord) async throws -> [CloudWorkspaceRecord]

    static let defaultWorkspaceURL = URL.documentsDirectory
        .appending(path: "Dahlia", directoryHint: .isDirectory)

    private(set) var workspaces: [WorkspaceRecord] = []
    private(set) var blockedSyncWorkspaceIDs: Set<UUID> = []
    private(set) var conflictedSyncWorkspaceIDs: Set<UUID> = []
    private(set) var validationBlockedSyncWorkspaceIDs: Set<UUID> = []
    private(set) var pendingServerAdoption: PendingWorkspaceServerAdoption?
    private(set) var errorMessage = ""
    private(set) var isLoading = false
    private(set) var isRemovingWorkspace = false
    private(set) var isRenamingWorkspace = false
    private(set) var updatingWorkspaceAccountID: UUID?
    var isShowingError = false

    private var appDatabase: AppDatabaseManager?
    private(set) var hasLoadedWorkspaces = false
    private var repository: MeetingRepository?
    private let cloudWorkspaceFetcher: CloudWorkspaceFetcher?
    private let organizationFetcher: ((DahliaAccountConnectionRecord) async throws -> [Components.Schemas.Organization])?
    private var syncObservation: AnyDatabaseCancellable?

    init(
        cloudWorkspaceFetcher: CloudWorkspaceFetcher? = nil,
        organizationFetcher: ((DahliaAccountConnectionRecord) async throws -> [Components.Schemas.Organization])? = nil
    ) {
        self.cloudWorkspaceFetcher = cloudWorkspaceFetcher
        self.organizationFetcher = organizationFetcher
    }

    func configure(appDatabase: AppDatabaseManager?) async {
        if self.appDatabase === appDatabase, hasLoadedWorkspaces {
            await loadWorkspaces()
            return
        }
        self.appDatabase = appDatabase
        hasLoadedWorkspaces = false
        repository = appDatabase.map { MeetingRepository(dbQueue: $0.dbQueue) }
        syncObservation?.cancel()
        if let dbQueue = appDatabase?.dbQueue {
            syncObservation = ValueObservation.tracking { db in
                try (
                    WorkspaceRecord.order(Column("lastOpenedAt").desc).fetchAll(db),
                    UUID.fetchSet(db, sql: "SELECT DISTINCT workspace_id FROM sync_transactions WHERE blockedReason IS NOT NULL"),
                    UUID.fetchSet(db, sql: "SELECT DISTINCT workspace_id FROM sync_transactions WHERE blockedReason = 'conflict'"),
                    UUID.fetchSet(db, sql: "SELECT DISTINCT workspace_id FROM sync_transactions WHERE blockedReason = 'validation'")
                )
            }.start(in: dbQueue, onError: { _ in }, onChange: { [weak self] values in
                Task { @MainActor in
                    guard let self, self.appDatabase?.dbQueue === dbQueue else { return }
                    self.workspaces = values.0
                    self.blockedSyncWorkspaceIDs = values.1
                    self.conflictedSyncWorkspaceIDs = values.2
                    self.validationBlockedSyncWorkspaceIDs = values.3
                }
            })
        }
        await loadWorkspaces()
    }

    func loadWorkspaces() async {
        guard let repository else {
            workspaces = []
            blockedSyncWorkspaceIDs = []
            conflictedSyncWorkspaceIDs = []
            validationBlockedSyncWorkspaceIDs = []
            hasLoadedWorkspaces = false
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            workspaces = try await repository.fetchAllWorkspacesAsync()
            blockedSyncWorkspaceIDs = try await repository.blockedSyncWorkspaceIDs()
            conflictedSyncWorkspaceIDs = try await repository.conflictedSyncWorkspaceIDs()
            validationBlockedSyncWorkspaceIDs = try await repository.validationBlockedSyncWorkspaceIDs()
            hasLoadedWorkspaces = true
        } catch {
            hasLoadedWorkspaces = false
            guard !Task.isCancelled else { return }
            presentError(L10n.workspaceLoadFailed, error: error, source: "loadWorkspaces")
        }
    }

    private func fetchCloudWorkspaces(from connection: DahliaAccountConnectionRecord) async throws -> [CloudWorkspaceRecord] {
        if let cloudWorkspaceFetcher {
            return try await cloudWorkspaceFetcher(connection)
        }
        let token = try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(connectionID: connection.id)
        return try await CloudWorkspaceDiscovery.fetch(connection: connection, token: token)
    }

    func resolveExistingStartupWorkspace(appDatabase: AppDatabaseManager) async -> WorkspaceRecord? {
        await configure(appDatabase: appDatabase)
        guard hasLoadedWorkspaces else { return nil }
        return workspaces.first(where: { $0.lastOpenedAt != .distantPast })
    }

    func createWorkspace(at url: URL) async -> WorkspaceRecord? {
        do {
            try await Self.createDirectory(at: url)
        } catch {
            guard !Task.isCancelled else { return nil }
            presentError(L10n.workspaceAddFailed, error: error, source: "createWorkspace.directory")
            return nil
        }
        return await registerWorkspace(at: url, markAsOpened: false)
    }

    func createWorkspace(named proposedName: String) async -> WorkspaceRecord? {
        guard let repository else {
            presentError(L10n.workspaceAddFailed, source: "createWorkspace")
            return nil
        }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let now = Date.now
        var workspace = WorkspaceRecord(
            id: .v7(),
            path: nil,
            name: name,
            createdAt: now,
            lastOpenedAt: .distantPast
        )
        WorkspaceAISettingsModel.shared.snapshot(for: workspace.id).applyAISettings(to: &workspace)
        do {
            try await repository.insertWorkspaceAsync(workspace)
            await loadWorkspaces()
            return workspace
        } catch {
            presentError(L10n.workspaceAddFailed, error: error, source: "createWorkspace")
            return nil
        }
    }

    func registerWorkspace(
        at url: URL,
        markAsOpened: Bool = true
    ) async -> WorkspaceRecord? {
        guard let repository else {
            presentError(L10n.workspaceAddFailed, source: "registerWorkspace")
            return nil
        }

        let normalizedURL = Self.normalizedFileURL(url)
        if let existingWorkspace = workspaces.first(where: {
            $0.url.map(Self.normalizedFileURL) == normalizedURL
        }) {
            return existingWorkspace
        }

        let now = Date.now
        var workspace = WorkspaceRecord(
            id: .v7(),
            path: normalizedURL.path,
            name: normalizedURL.lastPathComponent,
            createdAt: now,
            lastOpenedAt: markAsOpened ? now : .distantPast
        )
        WorkspaceAISettingsModel.shared.snapshot(for: workspace.id).applyAISettings(to: &workspace)

        do {
            try await repository.insertWorkspaceAsync(workspace)
            await loadWorkspaces()
            return workspace
        } catch {
            presentError(L10n.workspaceAddFailed, error: error, source: "registerWorkspace")
            return nil
        }
    }

    func markWorkspaceOpened(_ workspace: WorkspaceRecord) async -> Bool {
        guard let repository else {
            presentError(L10n.workspaceOperationFailed, source: "markWorkspaceOpened")
            return false
        }

        do {
            guard let updatedWorkspace = try await repository.updateWorkspaceLastOpened(id: workspace.id) else {
                presentError(L10n.workspaceOperationFailed, source: "markWorkspaceOpened")
                return false
            }
            if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                workspaces[index] = updatedWorkspace
            }
            return true
        } catch {
            presentError(L10n.workspaceOperationFailed, error: error, source: "markWorkspaceOpened")
            return false
        }
    }

    func setExportFolder(for workspace: WorkspaceRecord, to url: URL?) async -> WorkspaceRecord? {
        guard let repository else { return nil }
        let normalizedURL = url.map(Self.normalizedFileURL)
        if let normalizedURL,
           workspaces.contains(where: { $0.id != workspace.id && $0.url.map(Self.normalizedFileURL) == normalizedURL }) {
            return nil
        }
        do {
            if let normalizedURL {
                try await Self.createDirectory(at: normalizedURL)
            }
            guard let updated = try await repository.updateWorkspacePath(id: workspace.id, path: normalizedURL?.path) else {
                return nil
            }
            if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                workspaces[index] = updated
            }
            return updated
        } catch {
            presentError(L10n.workspaceFolderSelectionFailed, error: error, source: "setExportFolder")
            return nil
        }
    }

    func removeWorkspace(_ workspace: WorkspaceRecord, currentWorkspaceId: UUID?) async -> Bool {
        guard workspace.id != currentWorkspaceId else { return false }
        guard workspace.accountConnectionId == nil else { return false }
        guard !isRemovingWorkspace else { return false }
        guard let repository else {
            presentError(L10n.workspaceRemoveFailed, source: "removeWorkspace")
            return false
        }

        isRemovingWorkspace = true
        defer { isRemovingWorkspace = false }
        do {
            try await repository.deleteWorkspaceSafely(id: workspace.id)
            workspaces.removeAll(where: { $0.id == workspace.id })
            return true
        } catch {
            presentError(L10n.workspaceRemoveFailed, error: error, source: "removeWorkspace")
            return false
        }
    }

    func renameWorkspace(_ workspace: WorkspaceRecord, to proposedName: String, appearance: ProjectAppearance? = nil) async -> WorkspaceRecord? {
        guard workspace.allowsWorkspaceManagement else { return nil }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard name != workspace.name || (appearance != nil && appearance != workspace.appearance) else { return workspace }
        guard !isRenamingWorkspace else { return nil }
        guard let repository else {
            presentError(L10n.workspaceRenameFailed, source: "renameWorkspace")
            return nil
        }

        isRenamingWorkspace = true
        defer { isRenamingWorkspace = false }
        do {
            guard let renamedWorkspace = try await repository.updateWorkspaceName(id: workspace.id, name: name, appearance: appearance) else {
                presentError(L10n.workspaceRenameFailed, source: "renameWorkspace")
                return nil
            }
            if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
                workspaces[index] = renamedWorkspace
            }
            return renamedWorkspace
        } catch {
            presentError(L10n.workspaceRenameFailed, error: error, source: "renameWorkspace")
            return nil
        }
    }

    func requestServerAdoption(for workspace: WorkspaceRecord, connection: DahliaAccountConnection) async {
        guard updatingWorkspaceAccountID == nil,
              workspace.accountConnectionId == nil,
              connection.isSignedIn,
              connection.supportsWorkspaceSync
        else { return }
        updatingWorkspaceAccountID = workspace.id
        defer { updatingWorkspaceAccountID = nil }
        do {
            let serverWorkspaces = try await fetchCloudWorkspaces(from: connection.record)
            let organizations = try await fetchOrganizations(connection.record)
            if let repository {
                _ = try await MeetingRepository.registerDiscoveredCloudWorkspaces(
                    serverWorkspaces,
                    connection: connection.record,
                    dbQueue: repository.dbQueue
                )
            }
            pendingServerAdoption = PendingWorkspaceServerAdoption(
                workspace: workspace,
                connection: connection,
                serverWorkspaces: serverWorkspaces,
                organizations: organizations
            )
        } catch is CancellationError {
            return
        } catch {
            presentError(L10n.workspaceOperationFailed, error: error, source: "requestServerAdoption")
        }
    }

    private func fetchOrganizations(_ connection: DahliaAccountConnectionRecord) async throws -> [Components.Schemas.Organization] {
        if let organizationFetcher { return try await organizationFetcher(connection) }
        return try await CloudWorkspaceDiscovery.organizations(connection: connection, api: SyncAPIClient(session: .shared))
    }

    func reloadServerAdoption() async {
        guard let pending = pendingServerAdoption else { return }
        await requestServerAdoption(for: pending.workspace, connection: pending.connection)
    }

    func createAdoptionOrganization(name: String) async {
        guard let pending = pendingServerAdoption, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await CloudWorkspaceDiscovery.createOrganization(
                name: name,
                connection: pending.connection.record,
                api: SyncAPIClient(session: .shared)
            )
            await reloadServerAdoption()
        } catch { presentError(L10n.workspaceOperationFailed, error: error, source: "createAdoptionOrganization") }
    }

    func confirmServerAdoption(
        _ pending: PendingWorkspaceServerAdoption, destinationId: UUID?, organizationId: UUID?
    ) async -> WorkspaceRecord? {
        guard updatingWorkspaceAccountID == nil, let repository else { return nil }
        updatingWorkspaceAccountID = pending.workspace.id
        defer { updatingWorkspaceAccountID = nil }
        do {
            let api = SyncAPIClient(session: .shared)
            let connection = pending.connection.record
            let backup = BackupService(dbQueue: repository.dbQueue)
            let currentWorkspaces = try await fetchCloudWorkspaces(from: connection)
            let updated: WorkspaceRecord
            if let destinationId, destinationId != pending.workspace.id {
                guard let destination = currentWorkspaces.first(where: { $0.workspaceId == destinationId })
                else { throw LocalWorkspaceImportError.unavailable }
                updated = try await LocalWorkspaceImport.run(
                    sourceId: pending.workspace.id,
                    destination: destination,
                    dbQueue: repository.dbQueue,
                    backup: backup,
                    api: api
                )
            } else {
                guard let organizationId,
                      try await fetchOrganizations(connection)
                      .contains(where: { $0.id == organizationId.uuidString.lowercased() && $0.kind == .team }) else {
                    throw LocalWorkspaceImportError.unavailable
                }
                let fence = try await repository.dbQueue.read { db in
                    guard try DahliaAccountConnectionRecord.fetchOne(db, key: connection.id) == connection,
                          let source = try WorkspaceRecord.fetchOne(db, key: pending.workspace.id), source.accountConnectionId == nil,
                          try !RecordingSessionRecord.hasActiveRecording(workspaceId: source.id, in: db),
                          try !SyncTransactionQueue.hasPending(workspaceId: source.id, in: db) else { throw LocalWorkspaceImportError.unavailable }
                    return db.totalChangesCount
                }
                _ = try await backup.createGeneration(workspaceIds: [pending.workspace.id])
                if !currentWorkspaces.contains(where: { $0.workspaceId == pending.workspace.id }) {
                    try await CloudWorkspaceDiscovery.createWorkspace(
                        pending.workspace,
                        organizationId: organizationId,
                        connection: connection,
                        api: api
                    )
                }
                guard let serverWorkspace = try await fetchCloudWorkspaces(from: connection).first(where: { $0.workspaceId == pending.workspace.id }),
                      serverWorkspace.organizationId == organizationId, serverWorkspace.role == "admin",
                      let origin = URL(string: connection.origin) else { throw LocalWorkspaceImportError.unavailable }
                let snapshot = try await SyncWorker(dbQueue: repository.dbQueue, apiClient: api)
                    .importSnapshot(workspaceId: serverWorkspace.workspaceId, connectionId: connection.id, origin: origin)
                guard snapshot.projects.isEmpty, snapshot.meetings.isEmpty, snapshot.files.isEmpty else { throw LocalWorkspaceImportError.collision }
                guard try await fetchCloudWorkspaces(from: connection).contains(where: {
                    $0.workspaceId == serverWorkspace.workspaceId && $0.organizationId == organizationId && $0.role == "admin"
                }) else { throw LocalWorkspaceImportError.unavailable }
                guard let adopted = try await repository.adoptWorkspaceForServerSync(
                    id: pending.workspace.id,
                    connectionID: connection.id,
                    serverWorkspace: serverWorkspace,
                    expectedChanges: fence
                ) else {
                    throw LocalWorkspaceImportError.changed
                }
                updated = adopted
            }
            pendingServerAdoption = nil
            await loadWorkspaces()
            return updated
        } catch {
            presentError(L10n.workspaceOperationFailed, error: error, source: "confirmServerAdoption")
            return nil
        }
    }

    func cancelServerAdoption() {
        pendingServerAdoption = nil
    }

    func acceptServerSyncVersion(for workspace: WorkspaceRecord) async {
        guard let repository else { return }
        do {
            try await repository.acceptServerSyncVersion(workspaceId: workspace.id)
            blockedSyncWorkspaceIDs.remove(workspace.id)
            conflictedSyncWorkspaceIDs.remove(workspace.id)
        } catch {
            presentError(L10n.workspaceOperationFailed, error: error, source: "acceptServerSyncVersion")
        }
    }

    func reapplyLocalSyncVersion(for workspace: WorkspaceRecord) async {
        guard let repository else { return }
        do {
            try await repository.reapplyLocalSyncVersion(workspaceId: workspace.id)
            blockedSyncWorkspaceIDs.remove(workspace.id)
            conflictedSyncWorkspaceIDs.remove(workspace.id)
        } catch {
            presentError(L10n.workspaceOperationFailed, error: error, source: "reapplyLocalSyncVersion")
        }
    }

    func discardInvalidSyncTransaction(for workspace: WorkspaceRecord) async {
        guard let repository else { return }
        do {
            try await repository.discardInvalidSyncTransaction(workspaceId: workspace.id)
            blockedSyncWorkspaceIDs.remove(workspace.id)
            validationBlockedSyncWorkspaceIDs.remove(workspace.id)
        } catch {
            presentError(L10n.workspaceOperationFailed, error: error, source: "discardInvalidSyncTransaction")
        }
    }

    func retryInvalidSyncTransaction(for workspace: WorkspaceRecord) async {
        guard let repository else { return }
        do {
            try await repository.retryInvalidSyncTransaction(workspaceId: workspace.id)
            blockedSyncWorkspaceIDs.remove(workspace.id)
            validationBlockedSyncWorkspaceIDs.remove(workspace.id)
        } catch {
            presentError(L10n.workspaceOperationFailed, error: error, source: "retryInvalidSyncTransaction")
        }
    }

    func presentFolderSelectionError(_ error: any Error) {
        presentError(L10n.workspaceFolderSelectionFailed, error: error, source: "folderImport")
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
