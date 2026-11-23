import Foundation
import GRDB
import Observation

/// 初回起動と設定画面で共有するワークスペースの管理状態。
@MainActor
@Observable
final class WorkspaceManagementModel {
    /// The first workspace of the app's account.
    static let initialWorkspaceName = "Default"

    static let defaultWorkspaceURL = URL.documentsDirectory
        .appending(path: "Dahlia", directoryHint: .isDirectory)

    private(set) var workspaces: [WorkspaceRecord] = []
    private(set) var errorMessage = ""
    private(set) var isLoading = false
    private(set) var isRemovingWorkspace = false
    private(set) var isUpdatingOutputLanguage = false
    private(set) var isRenamingWorkspace = false
    var isShowingError = false

    private var appDatabase: AppDatabaseManager?
    private(set) var hasLoadedWorkspaces = false
    private var repository: MeetingRepository?
    @ObservationIgnored private var initialLocalWorkspaceTask: Task<WorkspaceRecord?, Never>?
    private var workspaceObservation: AnyDatabaseCancellable?

    func configure(appDatabase: AppDatabaseManager?) async {
        if self.appDatabase === appDatabase, hasLoadedWorkspaces {
            await loadWorkspaces()
            return
        }
        self.appDatabase = appDatabase
        hasLoadedWorkspaces = false
        repository = appDatabase.map { MeetingRepository(dbQueue: $0.dbQueue) }
        workspaceObservation?.cancel()
        if let dbQueue = appDatabase?.dbQueue {
            workspaceObservation = ValueObservation.tracking { db in
                try WorkspaceRecord.order(Column("lastOpenedAt").desc).fetchAll(db)
            }.start(in: dbQueue, onError: { _ in }, onChange: { [weak self] workspaces in
                Task { @MainActor in
                    guard let self, self.appDatabase?.dbQueue === dbQueue else { return }
                    self.workspaces = workspaces
                }
            })
        }
        await loadWorkspaces()
    }

    func loadWorkspaces() async {
        guard let repository else {
            workspaces = []
            hasLoadedWorkspaces = false
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            workspaces = try await repository.fetchAllWorkspacesAsync()
            hasLoadedWorkspaces = true
        } catch {
            hasLoadedWorkspaces = false
            guard !Task.isCancelled else { return }
            presentError(L10n.workspaceLoadFailed, error: error, source: "loadWorkspaces")
        }
    }

    func resolveExistingStartupWorkspace(appDatabase: AppDatabaseManager) async -> WorkspaceRecord? {
        await configure(appDatabase: appDatabase)
        guard hasLoadedWorkspaces else { return nil }
        return workspaces.first(where: { $0.lastOpenedAt != .distantPast })
    }

    func resolveInitialWorkspace() async -> WorkspaceRecord? {
        // Keep a committed workspace reusable even if the setup tour asks again during creation.
        if let initialLocalWorkspaceTask { return await initialLocalWorkspaceTask.value }
        let task = Task<WorkspaceRecord?, Never> { @MainActor in
            await self.loadWorkspaces()
            guard self.hasLoadedWorkspaces else { return nil }
            if let existing = self.workspaces.first { return existing }
            return await self.createWorkspace(named: Self.initialWorkspaceName)
        }
        initialLocalWorkspaceTask = task
        defer { initialLocalWorkspaceTask = nil }
        return await task.value
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

    func registerWorkspace(at url: URL, markAsOpened: Bool = true) async -> WorkspaceRecord? {
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

    func setOutputLanguage(for workspace: WorkspaceRecord, to language: SummaryLanguage) async -> WorkspaceRecord? {
        guard !isUpdatingOutputLanguage, let repository else { return nil }
        isUpdatingOutputLanguage = true
        defer { isUpdatingOutputLanguage = false }
        do {
            guard let updated = try await repository.updateWorkspaceOutputLanguage(id: workspace.id, language: language) else { return nil }
            if let index = workspaces.firstIndex(where: { $0.id == updated.id }) {
                workspaces[index] = updated
            }
            return updated
        } catch {
            presentError(L10n.workspaceOperationFailed, error: error, source: "setOutputLanguage")
            return nil
        }
    }

    func deletionTransferCandidates(for workspace: WorkspaceRecord) -> [WorkspaceRecord] {
        workspaces.filter {
            $0.id != workspace.id
        }
    }

    func removeWorkspace(_ workspace: WorkspaceRecord, currentWorkspaceId: UUID?, transferringTo destinationID: UUID? = nil) async -> Bool {
        guard workspace.id != currentWorkspaceId else { return false }
        guard !isRemovingWorkspace else { return false }
        guard let repository else {
            presentError(L10n.workspaceRemoveFailed, source: "removeWorkspace")
            return false
        }

        isRemovingWorkspace = true
        defer { isRemovingWorkspace = false }
        do {
            if let destinationID {
                try await repository.transferAndDeleteWorkspace(id: workspace.id, destinationID: destinationID)
            } else {
                try await repository.deleteWorkspaceSafely(id: workspace.id)
            }
            workspaces.removeAll(where: { $0.id == workspace.id })
            return true
        } catch {
            presentError(L10n.workspaceRemoveFailed, error: error, source: "removeWorkspace")
            return false
        }
    }

    func renameWorkspace(_ workspace: WorkspaceRecord, to proposedName: String, appearance: ProjectAppearance? = nil) async -> WorkspaceRecord? {
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
