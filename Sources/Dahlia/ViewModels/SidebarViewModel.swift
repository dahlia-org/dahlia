import DahliaRuntimeSupport
import Foundation
import GRDB
import Observation
import OSLog

let sidebarViewModelLogger = Logger(subsystem: "com.dahlia", category: "SidebarViewModel")

private struct ProjectDescriptionDraft {
    let description: String
    let baseRevision: Int?
}

/// サイドバーの状態管理。Vault 内のミーティング一覧と設定画面で使う補助データを監視する。
@Observable
@MainActor
final class SidebarViewModel {
    nonisolated static let meetingPageSize = 50
    nonisolated static let maximumVisibleMeetings = 500

    // MARK: - Observed State

    /// 現在の vault に属する全 project のフラット一覧。
    var flatProjects: [FlatProjectRow] = []
    /// SwiftUI の `List(selection:)` と直結するミーティング選択。
    var selectedMeetingIds: Set<UUID> = [] {
        didSet {
            guard oldValue != selectedMeetingIds else { return }
            startSelectedMeetingObservationIfNeeded()
        }
    }

    var meetingSidebarItems: [MeetingSidebarItem] = []
    var meetingSidebarGroups: [MeetingDateGroup] = []
    var isMeetingListLoaded = false
    var isMeetingListLoadingMore = false
    var meetingListLoadError: String?
    var hasMoreMeetings = false
    var meetingSearchQuery = ""
    var meetingSearchItems: [MeetingSidebarItem] = []
    var meetingSearchGroups: [MeetingDateGroup] = []
    var isMeetingSearchLoaded = true
    var isMeetingSearchLoadingMore = false
    var meetingSearchLoadError: String?
    var hasMoreMeetingSearchResults = false
    var isMeetingListLimited = false
    var isMeetingSearchLimited = false
    var selectedMeetingDetail: MeetingDetailItem?
    var meetingReferences: [CodexChatMeetingReference] = []
    var isMeetingCatalogLoaded = false
    /// 現在の vault に属する全 project の集約一覧。
    var allProjectItems: [ProjectOverviewItem] = []
    private(set) var isProjectCatalogLoaded = false
    private(set) var projectCatalogLoadFailed = false
    /// 現在の vault に属する全 instructions の一覧。
    var allInstructions: [InstructionRecord] = []
    var allVaults: [VaultRecord] = []
    var allTags: [TagRecord] = []
    private(set) var allAvailableTags: [TagInfo] = []
    var selectedInstruction: InstructionRecord?
    var lastError: String?

    var selectedMeetingId: UUID? {
        selectedMeetingIds.count == 1 ? selectedMeetingIds.first : nil
    }

    // MARK: - Active Database & Vault

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private(set) var appDatabase: AppDatabaseManager?
    var currentVault: VaultRecord? { settings.currentVault }
    var dbQueue: DatabaseQueue? { appDatabase?.dbQueue }

    @ObservationIgnored var meetingRepository: MeetingRepository?
    @ObservationIgnored var projectWorkspaceService: ProjectWorkspaceService?
    @ObservationIgnored private var fileWatcher: TranscriptFileWatcher?
    @ObservationIgnored var meetingListObservation: AnyDatabaseCancellable?
    @ObservationIgnored var additionalMeetingRowsObservation: AnyDatabaseCancellable?
    @ObservationIgnored var selectedMeetingObservation: AnyDatabaseCancellable?
    @ObservationIgnored var meetingReferencesObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var allTagsObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var allProjectsObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var projectCatalogObservationTracker = ProjectCatalogObservationTracker()
    @ObservationIgnored private var instructionsObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var projectObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var vaultObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var vaultSyncService: VaultSyncService?
    @ObservationIgnored private var projectDescriptionDrafts: [UUID: ProjectDescriptionDraft] = [:]
    @ObservationIgnored private var workspaceChangeObserver: NSObjectProtocol?
    @ObservationIgnored var meetingSearchTask: Task<Void, Never>?
    @ObservationIgnored var meetingPageLoadTask: Task<Void, Never>?
    @ObservationIgnored var meetingListCursor: MeetingSidebarCursor?
    @ObservationIgnored var meetingSearchCursor: MeetingSidebarCursor?
    @ObservationIgnored var meetingInitialPageIDs: [UUID] = []
    @ObservationIgnored var isMeetingCatalogRequested = false
    @ObservationIgnored var meetingListObservationGeneration = 0
    @ObservationIgnored var additionalMeetingRowsObservationGeneration = 0
    @ObservationIgnored var meetingSearchObservationGeneration = 0
    @ObservationIgnored var meetingPageLoadGeneration = 0
    @ObservationIgnored var selectedMeetingObservationGeneration = 0
    @ObservationIgnored var meetingReferencesObservationGeneration = 0

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    /// プロジェクト名から vault 内の URL を返す。
    func projectURL(for name: String) -> URL {
        currentVault!.url.appendingPathComponent(name, isDirectory: true)
    }

    /// 保管庫の最終オープン日時を更新する。
    func updateVaultLastOpened(_ id: UUID) {
        try? meetingRepository?.updateVaultLastOpened(id: id)
    }

    /// アプリ起動時に AppDatabaseManager と保管庫を設定する。
    /// 呼び出し前に設定の currentVault を設定しておくこと。
    func setAppDatabase(_ database: AppDatabaseManager?) {
        appDatabase = database
        meetingRepository = database.map { MeetingRepository(dbQueue: $0.dbQueue) }
        projectWorkspaceService = nil

        vaultSyncService?.stopMonitoring()
        projectObservation?.cancel()
        vaultObservation?.cancel()
        meetingListObservation?.cancel()
        additionalMeetingRowsObservation?.cancel()
        selectedMeetingObservation?.cancel()
        meetingReferencesObservation?.cancel()
        meetingSearchTask?.cancel()
        meetingPageLoadTask?.cancel()
        allTagsObservation?.cancel()
        allProjectsObservation?.cancel()
        projectCatalogObservationTracker.invalidate()
        instructionsObservation?.cancel()
        fileWatcher?.stopMonitoring()
        if let workspaceChangeObserver {
            DistributedNotificationCenter.default().removeObserver(workspaceChangeObserver)
            self.workspaceChangeObserver = nil
        }

        vaultSyncService = nil
        fileWatcher = nil
        flatProjects.removeAll()
        meetingSidebarItems.removeAll()
        meetingSidebarGroups.removeAll()
        isMeetingListLoaded = false
        isMeetingListLoadingMore = false
        meetingListLoadError = nil
        hasMoreMeetings = false
        meetingSearchQuery = ""
        meetingSearchItems.removeAll()
        meetingSearchGroups.removeAll()
        isMeetingSearchLoaded = true
        isMeetingSearchLoadingMore = false
        meetingSearchLoadError = nil
        hasMoreMeetingSearchResults = false
        isMeetingListLimited = false
        isMeetingSearchLimited = false
        selectedMeetingDetail = nil
        meetingReferences.removeAll()
        isMeetingCatalogLoaded = false
        meetingListCursor = nil
        meetingSearchCursor = nil
        meetingInitialPageIDs.removeAll()
        isMeetingCatalogRequested = false
        meetingListObservationGeneration &+= 1
        additionalMeetingRowsObservationGeneration &+= 1
        meetingSearchObservationGeneration &+= 1
        meetingPageLoadGeneration &+= 1
        selectedMeetingObservationGeneration &+= 1
        meetingReferencesObservationGeneration &+= 1
        allProjectItems.removeAll()
        isProjectCatalogLoaded = false
        projectCatalogLoadFailed = false
        projectDescriptionDrafts.removeAll()
        allInstructions.removeAll()
        allTags.removeAll()
        allAvailableTags.removeAll()
        selectedInstruction = nil
        clearMeetingSelection()

        guard let dbQueue = database?.dbQueue else {
            allVaults.removeAll()
            settings.selectedInstructionID = nil
            return
        }

        startVaultObservation(dbQueue: dbQueue)

        guard let vault = currentVault else {
            settings.selectedInstructionID = nil
            return
        }

        let vaultURL = vault.url
        let vaultId = vault.id
        if let meetingRepository {
            projectWorkspaceService = ProjectWorkspaceService(repository: meetingRepository, vault: vault)
        }

        let syncService = VaultSyncService(vaultURL: vaultURL, dbQueue: dbQueue, vaultId: vaultId)
        vaultSyncService = syncService
        syncService.startMonitoring()

        let watcher = TranscriptFileWatcher(dbQueue: dbQueue, vaultURL: vaultURL)
        watcher.startMonitoring()
        fileWatcher = watcher

        startProjectObservation(dbQueue: dbQueue, vaultId: vaultId)
        startMeetingListObservation(dbQueue: dbQueue, vaultId: vaultId)
        startTagsObservation(dbQueue: dbQueue)
        startProjectOverviewObservation(dbQueue: dbQueue, vaultId: vaultId)
        startInstructionsObservation(dbQueue: dbQueue, vaultId: vaultId)
        workspaceChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: DahliaWorkspaceChangeNotification.name(vaultID: vaultId),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.currentVault?.id == vaultId,
                      let dbQueue = self.dbQueue else { return }
                self.startProjectObservation(dbQueue: dbQueue, vaultId: vaultId)
                self.resetMeetingListPagination()
                self.startMeetingListObservation(dbQueue: dbQueue, vaultId: vaultId)
                if self.isMeetingCatalogRequested {
                    self.startMeetingReferencesObservation(dbQueue: dbQueue, vaultId: vaultId)
                }
                self.restartMeetingSearchIfNeeded(dbQueue: dbQueue, vaultId: vaultId)
                self.startSelectedMeetingObservationIfNeeded()
                self.startProjectOverviewObservation(dbQueue: dbQueue, vaultId: vaultId)
            }
        }
    }

    private func startVaultObservation(dbQueue: DatabaseQueue) {
        let observation = ValueObservation.tracking { db in
            try VaultRecord.order(Column("lastOpenedAt").desc).fetchAll(db)
        }
        vaultObservation = observation.start(
            in: dbQueue,
            onError: { _ in },
            onChange: { [weak self] vaults in
                Task { @MainActor in
                    guard let self, self.allVaults != vaults else { return }
                    self.allVaults = vaults
                }
            }
        )
    }

    private func startProjectObservation(dbQueue: DatabaseQueue, vaultId: UUID) {
        let observation = ValueObservation.tracking { db in
            try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
        }
        projectObservation = observation.start(
            in: dbQueue,
            onError: { _ in },
            onChange: { [weak self] records in
                Task { @MainActor in
                    guard let self else { return }
                    let rows = FlatProjectRow.buildRows(fromRecords: records)
                    guard self.flatProjects != rows else { return }
                    self.flatProjects = rows
                }
            }
        )
    }

    private func startTagsObservation(dbQueue: DatabaseQueue) {
        let observation = ValueObservation.tracking { db in
            try TagRecord.order(Column("name").asc).fetchAll(db)
        }
        allTagsObservation = observation.start(
            in: dbQueue,
            onError: { _ in },
            onChange: { [weak self] tags in
                Task { @MainActor in
                    guard let self else { return }
                    self.allTags = tags
                    self.allAvailableTags = tags.map { TagInfo(name: $0.name, colorHex: $0.colorHex) }
                }
            }
        )
    }

    private func startProjectOverviewObservation(dbQueue: DatabaseQueue, vaultId: UUID) {
        allProjectsObservation?.cancel()
        let observationGeneration = projectCatalogObservationTracker.beginObservation()
        isProjectCatalogLoaded = false
        projectCatalogLoadFailed = false
        let observation = ValueObservation.tracking { db in
            let projectRecords = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
            let aggregateRows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    projects.id AS projectId,
                    COUNT(meetings.id) AS meetingCount,
                    MAX(meetings.createdAt) AS latestMeetingDate
                FROM projects
                LEFT JOIN meetings ON meetings.projectId = projects.id
                WHERE projects.vaultId = ?
                GROUP BY projects.id
                """,
                arguments: [vaultId]
            )
            let aggregates = Dictionary(uniqueKeysWithValues: aggregateRows.map { row -> (UUID, (Int, Date?)) in
                let id: UUID = row["projectId"]
                let count: Int = row["meetingCount"]
                let latest: Date? = row["latestMeetingDate"]
                return (id, (count, latest))
            })
            let effectiveTypes = ProjectRecord.effectiveTypes(projectRecords)
            return projectRecords.map { project in
                let effectiveType = effectiveTypes[project.id]
                return ProjectOverviewItem(
                    projectId: project.id,
                    projectName: project.path,
                    projectDisplayName: project.name,
                    parentProjectId: project.parentProjectId,
                    projectDescription: project.description,
                    explicitProjectType: project.projectType,
                    effectiveProjectType: effectiveType?.type ?? .undefined,
                    typeOwnerProjectId: effectiveType?.ownerProjectId,
                    revision: project.revision,
                    createdAt: project.createdAt,
                    meetingCount: aggregates[project.id]?.0 ?? 0,
                    latestMeetingDate: aggregates[project.id]?.1
                )
            }
        }
        allProjectsObservation = observation.start(
            in: dbQueue,
            onError: { [weak self] error in
                sidebarViewModelLogger.error("Failed to load project catalog: \(error, privacy: .public)")
                ErrorReportingService.capture(error, context: ["source": "projectCatalogObservation"])
                Task { @MainActor in
                    guard let self,
                          self.currentVault?.id == vaultId,
                          self.projectCatalogObservationTracker.isCurrent(observationGeneration) else { return }
                    self.isProjectCatalogLoaded = true
                    self.projectCatalogLoadFailed = true
                }
            },
            onChange: { [weak self] projects in
                Task { @MainActor in
                    guard let self,
                          self.currentVault?.id == vaultId,
                          self.projectCatalogObservationTracker.isCurrent(observationGeneration) else { return }
                    self.allProjectItems = projects
                    self.isProjectCatalogLoaded = true
                    self.projectCatalogLoadFailed = false
                }
            }
        )
    }

    private func startInstructionsObservation(dbQueue: DatabaseQueue, vaultId: UUID) {
        let observation = ValueObservation.tracking { db in
            try InstructionRecord
                .filter(Column("vaultId") == vaultId)
                .order(Column("name").asc)
                .fetchAll(db)
        }
        instructionsObservation = observation.start(
            in: dbQueue,
            onError: { _ in },
            onChange: { [weak self] instructions in
                Task { @MainActor in
                    guard let self else { return }
                    self.allInstructions = instructions

                    if let selectedInstruction = self.selectedInstruction {
                        let updated = instructions.first(where: { $0.id == selectedInstruction.id })
                        if updated != selectedInstruction {
                            self.selectedInstruction = updated
                        }
                    }

                    if let selectedInstructionID = self.settings.selectedInstructionID,
                       !instructions.contains(where: { $0.id == selectedInstructionID }) {
                        self.settings.selectedInstructionID = nil
                    }
                }
            }
        )
    }

    // MARK: - Selection

    func selectMeeting(_ id: UUID) {
        selectedMeetingIds = [id]
    }

    func clearMeetingSelection() {
        if !selectedMeetingIds.isEmpty {
            selectedMeetingIds.removeAll()
        }
    }

    func selectInstruction(_ id: UUID?) {
        guard let id else {
            selectedInstruction = nil
            return
        }
        selectedInstruction = allInstructions.first(where: { $0.id == id })
    }

    // MARK: - Instruction CRUD

    func useInstructionForSummary(_ instructionID: UUID?) {
        settings.selectedInstructionID = instructionID
    }

    func createInstruction() -> InstructionRecord? {
        guard let vault = currentVault,
              let meetingRepository else { return nil }

        do {
            let instruction = try meetingRepository.createInstruction(
                vaultId: vault.id,
                name: nextInstructionName(),
                content: AppSettings.defaultSummaryPrompt
            )
            selectedInstruction = instruction
            return instruction
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func updateInstruction(id: UUID, name: String, content: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        do {
            try meetingRepository?.updateInstruction(id: id, name: trimmedName, content: content)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteInstruction(id: UUID) {
        do {
            try meetingRepository?.deleteInstruction(id: id)
            if selectedInstruction?.id == id {
                selectedInstruction = nil
            }
            if settings.selectedInstructionID == id {
                settings.selectedInstructionID = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func nextInstructionName() -> String {
        let existingNames = Set(allInstructions.map(\.name))
        var name = "new_instruction"
        var counter = 1

        while existingNames.contains(name) {
            name = "new_instruction_\(counter)"
            counter += 1
        }

        return name
    }

    // MARK: - Project Helpers

    func retryProjectCatalogLoading() {
        guard let dbQueue, let vault = currentVault else { return }
        startProjectOverviewObservation(dbQueue: dbQueue, vaultId: vault.id)
    }

    func createProject(
        name: String,
        parentProjectId: UUID?,
        projectType: ProjectType? = nil
    ) -> ProjectRecord? {
        guard let projectWorkspaceService else { return nil }
        do {
            let project = try projectWorkspaceService.createProject(
                name: name,
                parentProjectId: parentProjectId,
                projectType: projectType
            )
            lastError = nil
            return project
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func renameProject(
        id: UUID,
        newName: String,
        expectedRevision: Int? = nil
    ) -> ProjectRecord? {
        guard let projectWorkspaceService else { return nil }
        do {
            let project = try projectWorkspaceService.renameProject(
                id: id,
                newName: newName,
                expectedRevision: expectedRevision
            )
            lastError = nil
            return project
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func reparentProject(
        id: UUID,
        parentProjectId: UUID?,
        expectedRevision: Int? = nil
    ) -> ProjectRecord? {
        guard let projectWorkspaceService else { return nil }
        do {
            let project = try projectWorkspaceService.reparentProject(
                id: id,
                parentProjectId: parentProjectId,
                expectedRevision: expectedRevision
            )
            lastError = nil
            return project
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func updateRootProjectType(
        id: UUID,
        projectType: ProjectType,
        expectedRevision: Int? = nil
    ) -> ProjectRecord? {
        guard let projectWorkspaceService else { return nil }
        do {
            let project = try projectWorkspaceService.updateRootProjectType(
                id: id,
                projectType: projectType,
                expectedRevision: expectedRevision
            )
            lastError = nil
            return project
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func updateProject(
        id: UUID,
        name: String,
        parentProjectId: UUID?,
        projectType: ProjectType,
        description: String,
        expectedRevision: Int
    ) async -> ProjectRecord? {
        guard let projectWorkspaceService else { return nil }
        do {
            let project = try await Task.detached(priority: .userInitiated) {
                try projectWorkspaceService.updateProject(
                    id: id,
                    name: name,
                    parentProjectId: parentProjectId,
                    projectType: projectType,
                    description: description,
                    expectedRevision: expectedRevision
                )
            }.value
            lastError = nil
            return project
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func deleteProjectHierarchy(
        id: UUID,
        meetingDisposition: ProjectMeetingDisposition,
        deletesSummaryFiles: Bool = false
    ) async -> Bool {
        guard let projectWorkspaceService else { return false }
        do {
            try await projectWorkspaceService.deleteProjectHierarchy(
                id: id,
                meetingDisposition: meetingDisposition,
                deletesSummaryFiles: deletesSummaryFiles
            )
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// プロジェクトを取得または作成し、派生する Summary 書き出し先 URL を返す。
    func fetchOrCreateProject(name: String) -> (record: ProjectRecord, url: URL)? {
        guard let vault = currentVault,
              let projectWorkspaceService else { return nil }

        do {
            let record = try projectWorkspaceService.fetchOrCreateRootProject(name: name)
            let projectURL = vault.url.appending(path: record.path, directoryHint: .isDirectory)
            return (record, projectURL)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

}

extension SidebarViewModel {
    func updateProjectDescription(
        id: UUID,
        description: String,
        expectedRevision: Int? = nil
    ) -> ProjectDescriptionUpdateResult {
        guard let meetingRepository else { return .failed }
        do {
            guard try meetingRepository.fetchProject(id: id) != nil else {
                clearProjectDescriptionDraft(id: id)
                return .projectNotFound
            }
            let updated: Bool
            if let projectWorkspaceService {
                updated = try projectWorkspaceService.updateProjectDescription(
                    id: id,
                    description: description,
                    expectedRevision: expectedRevision
                )
            } else {
                guard let vaultId = currentVault?.id else { return .failed }
                updated = try meetingRepository.updateProjectDescription(
                    id: id,
                    vaultId: vaultId,
                    description: description
                )
            }
            guard updated else {
                clearProjectDescriptionDraft(id: id)
                return .projectNotFound
            }
            clearProjectDescriptionDraft(id: id)
            return .saved
        } catch ProjectWorkspaceError.projectNotFound {
            clearProjectDescriptionDraft(id: id)
            return .projectNotFound
        } catch let ProjectWorkspaceError.staleRevision(current) {
            stageProjectDescriptionDraft(
                id: id,
                description: description,
                baseRevision: expectedRevision
            )
            return .staleRevision(current: current)
        } catch {
            stageProjectDescriptionDraft(
                id: id,
                description: description,
                baseRevision: expectedRevision
            )
            lastError = error.localizedDescription
            return .failed
        }
    }

    func stageProjectDescriptionDraft(
        id: UUID,
        description: String,
        baseRevision: Int? = nil
    ) {
        projectDescriptionDrafts[id] = ProjectDescriptionDraft(
            description: description,
            baseRevision: baseRevision
        )
    }

    func clearProjectDescriptionDraft(id: UUID) {
        projectDescriptionDrafts[id] = nil
    }

    func projectDescriptionDraft(id: UUID) -> String? {
        projectDescriptionDrafts[id]?.description
    }

    func projectDescriptionDraftBaseRevision(id: UUID) -> Int? {
        projectDescriptionDrafts[id]?.baseRevision
    }

    func projectDescription(id: UUID) -> String? {
        do {
            return try meetingRepository?.fetchProject(id: id)?.description
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
