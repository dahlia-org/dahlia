import DahliaRuntimeSupport
import Foundation
import GRDB
import Observation
import OSLog

let sidebarViewModelLogger = Logger(subsystem: "com.dahlia", category: "SidebarViewModel")

/// サイドバーの状態管理。Workspace 内のミーティング一覧と設定画面で使う補助データを監視する。
@Observable
@MainActor
final class SidebarViewModel {
    typealias UnprocessedRecordingDiscarder = @MainActor @Sendable (DatabaseQueue, UUID, UUID) async throws -> Bool

    nonisolated static let meetingPageSize = 50
    nonisolated static let maximumVisibleMeetings = 500

    var canEditCurrentWorkspace: Bool {
        currentWorkspace?.allowsCanonicalEdits == true
    }

    // MARK: - Observed State

    /// 現在の workspace に属する全 project のフラット一覧。
    var flatProjects: [FlatProjectRow] = []
    private(set) var areSearchProjectsLoaded = false
    /// SwiftUI の `List(selection:)` と直結するミーティング選択。
    var selectedMeetingIds: Set<UUID> = [] {
        didSet {
            guard oldValue != selectedMeetingIds else { return }
            startSelectedMeetingObservationIfNeeded()
        }
    }

    /// 別プロセスが同じ Workspace を変更するたびに増える。
    /// GRDB の `ValueObservation` は他プロセスの書き込みを検知しないため、これが跨プロセス更新の合図になる。
    private(set) var workspaceChangeToken: UInt64 = 0
    private(set) var searchIndexRevision = 0

    var meetingSidebarItems: [MeetingSidebarItem] = []
    var meetingSidebarGroups: [MeetingDateGroup] = []
    var isMeetingListLoaded = false
    var isMeetingListLoadingMore = false
    var meetingListLoadError: String?
    var hasMoreMeetings = false
    var meetingSearchCriteria = MeetingSearchCriteria()
    var meetingSearchItems: [MeetingSidebarItem] = []
    var meetingSearchGroups: [MeetingDateGroup] = []
    var isMeetingSearchLoaded = true
    var isMeetingSearchLoadingMore = false
    var meetingSearchLoadError: String?
    var hasMoreMeetingSearchResults = false
    var isMeetingListLimited = false
    var isMeetingSearchLimited = false
    var projectMeetingItemsByKey: [MeetingProjectKey: [MeetingSidebarItem]] = [:]
    var projectMeetingHasMoreByKey: [MeetingProjectKey: Bool] = [:]
    var projectMeetingLoadingKeys: Set<MeetingProjectKey> = []
    var projectMeetingLoadErrors: [MeetingProjectKey: String] = [:]
    var projectMeetingLimitedKeys: Set<MeetingProjectKey> = []
    var isProjectMeetingProjectionLoaded = false
    var isProjectMeetingProjectionLimited = false
    var projectMeetingProjectionLoadError: String?
    var projectMeetingUnassignedCount = 0
    var selectedMeetingDetail: MeetingDetailItem?
    var selectedMeetingDetailLoadError: String?
    var meetingReferences: [CodexChatMeetingReference] = []
    var isMeetingCatalogLoaded = false
    /// 現在の workspace に属する全 project の集約一覧。
    var allProjectItems: [ProjectOverviewItem] = [] {
        didSet {
            projectItemsByID = Dictionary(uniqueKeysWithValues: allProjectItems.map { ($0.projectId, $0) })
        }
    }

    @ObservationIgnored private(set) var projectItemsByID: [UUID: ProjectOverviewItem] = [:]
    private(set) var isProjectCatalogLoaded = false
    private(set) var projectCatalogLoadFailed = false
    /// 現在の workspace に属する全 instructions の一覧。
    var allInstructions: [InstructionRecord] = []
    var allWorkspaces: [WorkspaceRecord] = []
    var allTags: [TagRecord] = []
    private(set) var areSearchTagsLoaded = false
    private(set) var allAvailableTags: [TagInfo] = []
    var selectedInstruction: InstructionRecord?
    var lastError: String?
    private(set) var unprocessedRecordingItems: [BackupPreflightItem] = []
    private(set) var unprocessedRecordingsError: String?
    private(set) var isLoadingUnprocessedRecordings = false

    var selectedMeetingId: UUID? {
        selectedMeetingIds.count == 1 ? selectedMeetingIds.first : nil
    }

    // MARK: - Active Database & Workspace

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let unprocessedRecordingDiscarder: UnprocessedRecordingDiscarder
    @ObservationIgnored private(set) var appDatabase: AppDatabaseManager?
    var currentWorkspace: WorkspaceRecord? { settings.currentWorkspace }
    var dbQueue: DatabaseQueue? { appDatabase?.dbQueue }
    var searchDBQueue: DatabaseQueue? { appDatabase?.searchDBQueue }

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
    @ObservationIgnored private var unprocessedRecordingsContextGeneration: UInt64 = 0
    @ObservationIgnored private var unprocessedRecordingsRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var instructionsObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var projectObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var workspaceObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var searchIndexObservation: AnyDatabaseCancellable?
    @ObservationIgnored private(set) var searchIndexRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var hasObservedSearchIndexRevision = false
    @ObservationIgnored private var workspaceSyncService: WorkspaceSyncService?
    @ObservationIgnored private var workspaceChangeObserver: NSObjectProtocol?
    @ObservationIgnored var meetingSearchTask: Task<Void, Never>?
    @ObservationIgnored var meetingPageLoadTask: Task<Void, Never>?
    @ObservationIgnored var projectMeetingObservation: AnyDatabaseCancellable?
    @ObservationIgnored var isProjectMeetingProjectionRequested = false
    @ObservationIgnored var projectMeetingLoadTasks: [MeetingProjectKey: Task<Void, Never>] = [:]
    @ObservationIgnored var meetingListCursor: MeetingSidebarCursor?
    @ObservationIgnored var meetingSearchCursor: MeetingSearchCursor?
    @ObservationIgnored var activeMeetingSearchRankingPolicy: MeetingSearchRankingPolicy?
    @ObservationIgnored var meetingInitialPageIDs: [UUID] = []
    @ObservationIgnored var isMeetingCatalogRequested = false
    @ObservationIgnored var meetingListObservationGeneration = 0
    @ObservationIgnored var additionalMeetingRowsObservationGeneration = 0
    @ObservationIgnored var meetingSearchObservationGeneration = 0
    @ObservationIgnored var meetingPageLoadGeneration = 0
    @ObservationIgnored var selectedMeetingObservationGeneration = 0
    @ObservationIgnored var meetingReferencesObservationGeneration = 0
    @ObservationIgnored var projectMeetingObservationGeneration = 0
    @ObservationIgnored var projectMeetingLoadGenerations: [MeetingProjectKey: Int] = [:]
    @ObservationIgnored private var projectObservationGeneration = 0
    @ObservationIgnored private var tagObservationGeneration = 0

    init(
        settings: AppSettings = .shared,
        unprocessedRecordingDiscarder: @escaping UnprocessedRecordingDiscarder = { dbQueue, sessionId, workspaceId in
            try await MeetingRepository(dbQueue: dbQueue).discardUnprocessedBatchSessionSafely(
                id: sessionId,
                expectedWorkspaceId: workspaceId
            )
        }
    ) {
        self.settings = settings
        self.unprocessedRecordingDiscarder = unprocessedRecordingDiscarder
    }

    /// プロジェクト名から workspace 内の URL を返す。
    func projectURL(for name: String) -> URL? {
        currentWorkspace?.url?.appendingPathComponent(name, isDirectory: true)
    }

    func refreshCurrentWorkspaceFilesystemServices(_ workspace: WorkspaceRecord) {
        guard currentWorkspace?.id == workspace.id,
              let dbQueue,
              let meetingRepository else { return }
        projectWorkspaceService = ProjectWorkspaceService(repository: meetingRepository, workspace: workspace)
        workspaceSyncService?.stopMonitoring()
        fileWatcher?.stopMonitoring()
        workspaceSyncService = nil
        fileWatcher = nil
        guard let workspaceURL = workspace.url else { return }
        let syncService = WorkspaceSyncService(workspaceURL: workspaceURL, dbQueue: dbQueue, workspaceId: workspace.id)
        workspaceSyncService = syncService
        syncService.startMonitoring()
        let watcher = TranscriptFileWatcher(dbQueue: dbQueue, workspaceURL: workspaceURL)
        watcher.startMonitoring()
        fileWatcher = watcher
    }

    /// アプリ起動時に AppDatabaseManager とワークスペースを設定する。
    /// 呼び出し前に設定の currentWorkspace を設定しておくこと。
    func setAppDatabase(_ database: AppDatabaseManager?) {
        appDatabase = database
        meetingRepository = database.map { MeetingRepository(dbQueue: $0.dbQueue) }
        projectWorkspaceService = nil

        workspaceSyncService?.stopMonitoring()
        projectObservation?.cancel()
        workspaceObservation?.cancel()
        searchIndexObservation?.cancel()
        searchIndexRefreshTask?.cancel()
        meetingListObservation?.cancel()
        additionalMeetingRowsObservation?.cancel()
        selectedMeetingObservation?.cancel()
        meetingReferencesObservation?.cancel()
        projectMeetingObservation?.cancel()
        meetingSearchTask?.cancel()
        meetingPageLoadTask?.cancel()
        projectMeetingLoadTasks.values.forEach { $0.cancel() }
        projectMeetingLoadTasks.removeAll()
        allTagsObservation?.cancel()
        allProjectsObservation?.cancel()
        projectCatalogObservationTracker.invalidate()
        instructionsObservation?.cancel()
        fileWatcher?.stopMonitoring()
        if let workspaceChangeObserver {
            DistributedNotificationCenter.default().removeObserver(workspaceChangeObserver)
            self.workspaceChangeObserver = nil
        }

        workspaceSyncService = nil
        fileWatcher = nil
        searchIndexRevision = 0
        hasObservedSearchIndexRevision = false
        flatProjects.removeAll()
        areSearchProjectsLoaded = false
        meetingSidebarItems.removeAll()
        meetingSidebarGroups.removeAll()
        isMeetingListLoaded = false
        isMeetingListLoadingMore = false
        meetingListLoadError = nil
        hasMoreMeetings = false
        meetingSearchCriteria = MeetingSearchCriteria()
        meetingSearchItems.removeAll()
        meetingSearchGroups.removeAll()
        isMeetingSearchLoaded = true
        isMeetingSearchLoadingMore = false
        meetingSearchLoadError = nil
        hasMoreMeetingSearchResults = false
        isMeetingListLimited = false
        isMeetingSearchLimited = false
        projectMeetingItemsByKey.removeAll()
        projectMeetingHasMoreByKey.removeAll()
        projectMeetingLoadingKeys.removeAll()
        projectMeetingLoadErrors.removeAll()
        projectMeetingLimitedKeys.removeAll()
        isProjectMeetingProjectionLoaded = false
        isProjectMeetingProjectionLimited = false
        projectMeetingProjectionLoadError = nil
        projectMeetingUnassignedCount = 0
        selectedMeetingDetail = nil
        selectedMeetingDetailLoadError = nil
        meetingReferences.removeAll()
        isMeetingCatalogLoaded = false
        meetingListCursor = nil
        meetingSearchCursor = nil
        activeMeetingSearchRankingPolicy = nil
        meetingInitialPageIDs.removeAll()
        isMeetingCatalogRequested = false
        meetingListObservationGeneration &+= 1
        additionalMeetingRowsObservationGeneration &+= 1
        meetingSearchObservationGeneration &+= 1
        meetingPageLoadGeneration &+= 1
        selectedMeetingObservationGeneration &+= 1
        meetingReferencesObservationGeneration &+= 1
        projectMeetingObservationGeneration &+= 1
        projectMeetingLoadGenerations.removeAll()
        projectObservationGeneration &+= 1
        tagObservationGeneration &+= 1
        unprocessedRecordingsContextGeneration &+= 1
        unprocessedRecordingsRefreshGeneration &+= 1
        allProjectItems.removeAll()
        isProjectCatalogLoaded = false
        projectCatalogLoadFailed = false
        allInstructions.removeAll()
        allTags.removeAll()
        areSearchTagsLoaded = false
        allAvailableTags.removeAll()
        selectedInstruction = nil
        unprocessedRecordingItems.removeAll()
        unprocessedRecordingsError = nil
        isLoadingUnprocessedRecordings = false
        clearMeetingSelection()

        guard let dbQueue = database?.dbQueue else {
            allWorkspaces.removeAll()
            settings.selectedInstructionID = nil
            return
        }

        startWorkspaceObservation(dbQueue: dbQueue)
        startSearchIndexObservation(dbQueue: dbQueue)

        guard let workspace = currentWorkspace else {
            settings.selectedInstructionID = nil
            return
        }

        let workspaceId = workspace.id
        if let meetingRepository {
            projectWorkspaceService = ProjectWorkspaceService(repository: meetingRepository, workspace: workspace)
        }

        if let workspaceURL = workspace.url {
            let syncService = WorkspaceSyncService(workspaceURL: workspaceURL, dbQueue: dbQueue, workspaceId: workspaceId)
            workspaceSyncService = syncService
            syncService.startMonitoring()

            let watcher = TranscriptFileWatcher(dbQueue: dbQueue, workspaceURL: workspaceURL)
            watcher.startMonitoring()
            fileWatcher = watcher
        }

        startProjectObservation(dbQueue: dbQueue, workspaceId: workspaceId)
        startMeetingListObservation(dbQueue: dbQueue, workspaceId: workspaceId)
        if isProjectMeetingProjectionRequested {
            startProjectMeetingObservation(dbQueue: dbQueue, workspaceId: workspaceId)
        }
        startTagsObservation(dbQueue: dbQueue)
        startProjectOverviewObservation(dbQueue: dbQueue, workspaceId: workspaceId)
        startInstructionsObservation(dbQueue: dbQueue, workspaceId: workspaceId)
        Task { await refreshUnprocessedRecordings() }
        workspaceChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: DahliaWorkspaceChangeNotification.name(workspaceID: workspaceId),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.currentWorkspace?.id == workspaceId,
                      let dbQueue = self.dbQueue else { return }
                self.startProjectObservation(dbQueue: dbQueue, workspaceId: workspaceId)
                self.resetMeetingListPagination()
                self.startMeetingListObservation(dbQueue: dbQueue, workspaceId: workspaceId)
                if self.isProjectMeetingProjectionRequested {
                    self.startProjectMeetingObservation(dbQueue: dbQueue, workspaceId: workspaceId)
                }
                if self.isMeetingCatalogRequested {
                    self.startMeetingReferencesObservation(dbQueue: dbQueue, workspaceId: workspaceId)
                }
                self.restartMeetingSearchIfNeeded(dbQueue: dbQueue, workspaceId: workspaceId)
                self.startSelectedMeetingObservationIfNeeded()
                self.startProjectOverviewObservation(dbQueue: dbQueue, workspaceId: workspaceId)
                await self.refreshUnprocessedRecordings()
                self.workspaceChangeToken &+= 1
            }
        }
    }

    private func startSearchIndexObservation(dbQueue: DatabaseQueue) {
        searchIndexObservation?.cancel()
        searchIndexRefreshTask?.cancel()
        let observation = ValueObservation.tracking { db in
            try Int.fetchOne(
                db,
                sql: "SELECT indexRevision FROM search_index_state WHERE indexKind = 'fts'"
            ) ?? 0
        }.removeDuplicates()
        searchIndexObservation = observation.start(
            in: dbQueue,
            scheduling: .async(onQueue: .main),
            onError: { _ in },
            onChange: { [weak self] revision in
                Task { @MainActor [weak self] in
                    guard let self, self.dbQueue === dbQueue else { return }
                    guard self.hasObservedSearchIndexRevision else {
                        self.hasObservedSearchIndexRevision = true
                        self.searchIndexRevision = revision
                        return
                    }
                    guard revision != self.searchIndexRevision else { return }
                    self.searchIndexRevision = revision
                    self.searchIndexRefreshTask?.cancel()
                    self.searchIndexRefreshTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled, let self else { return }
                        self.restartCurrentMeetingSearch()
                    }
                }
            }
        )
    }

    func refreshUnprocessedRecordings() async {
        guard let dbQueue, let workspaceId = currentWorkspace?.id else {
            unprocessedRecordingItems = []
            unprocessedRecordingsError = nil
            isLoadingUnprocessedRecordings = false
            return
        }
        unprocessedRecordingsRefreshGeneration &+= 1
        let generation = unprocessedRecordingsRefreshGeneration
        isLoadingUnprocessedRecordings = true
        do {
            let items = try await BackupService(dbQueue: dbQueue).preflightItems(workspaceId: workspaceId)
            guard isCurrentUnprocessedRecordingsRefresh(generation, workspaceId: workspaceId) else { return }
            unprocessedRecordingItems = items
            unprocessedRecordingsError = nil
            isLoadingUnprocessedRecordings = false
        } catch {
            guard isCurrentUnprocessedRecordingsRefresh(generation, workspaceId: workspaceId) else { return }
            unprocessedRecordingsError = error.localizedDescription
            isLoadingUnprocessedRecordings = false
        }
    }

    private func isCurrentUnprocessedRecordingsRefresh(_ generation: UInt64, workspaceId: UUID) -> Bool {
        generation == unprocessedRecordingsRefreshGeneration && currentWorkspace?.id == workspaceId
    }

    func discardUnprocessedRecording(_ item: BackupPreflightItem) async {
        guard let dbQueue, let workspaceId = currentWorkspace?.id, item.workspaceId == workspaceId else { return }
        let contextGeneration = unprocessedRecordingsContextGeneration
        unprocessedRecordingsError = nil
        do {
            _ = try await unprocessedRecordingDiscarder(dbQueue, item.sessionId, item.workspaceId)
            guard isCurrentUnprocessedRecordingsContext(contextGeneration, workspaceId: workspaceId) else { return }
            await refreshUnprocessedRecordings()
        } catch {
            guard isCurrentUnprocessedRecordingsContext(contextGeneration, workspaceId: workspaceId) else { return }
            unprocessedRecordingsError = error.localizedDescription
        }
    }

    private func isCurrentUnprocessedRecordingsContext(_ generation: UInt64, workspaceId: UUID) -> Bool {
        generation == unprocessedRecordingsContextGeneration && currentWorkspace?.id == workspaceId
    }

    private func startWorkspaceObservation(dbQueue: DatabaseQueue) {
        let observation = ValueObservation.tracking { db in
            try WorkspaceRecord.order(Column("lastOpenedAt").desc).fetchAll(db)
        }
        workspaceObservation = observation.start(
            in: dbQueue,
            onError: { _ in },
            onChange: { [weak self] workspaces in
                Task { @MainActor in
                    guard let self, self.allWorkspaces != workspaces else { return }
                    self.allWorkspaces = workspaces
                }
            }
        )
    }

    private func startProjectObservation(dbQueue: DatabaseQueue, workspaceId: UUID) {
        projectObservation?.cancel()
        projectObservationGeneration &+= 1
        let generation = projectObservationGeneration
        areSearchProjectsLoaded = false
        let observation = ValueObservation.tracking { db in
            try ProjectRecord.fetchResolvedAll(workspaceId: workspaceId, in: db)
        }
        projectObservation = observation.start(
            in: dbQueue,
            onError: { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          self.currentWorkspace?.id == workspaceId,
                          self.projectObservationGeneration == generation else { return }
                    self.areSearchProjectsLoaded = true
                }
            },
            onChange: { [weak self] records in
                Task { @MainActor in
                    guard let self,
                          self.currentWorkspace?.id == workspaceId,
                          self.projectObservationGeneration == generation else { return }
                    let rows = FlatProjectRow.buildRows(fromRecords: records)
                    if self.flatProjects != rows {
                        self.flatProjects = rows
                    }
                    self.areSearchProjectsLoaded = true
                }
            }
        )
    }

    private func startTagsObservation(dbQueue: DatabaseQueue) {
        allTagsObservation?.cancel()
        tagObservationGeneration &+= 1
        let generation = tagObservationGeneration
        areSearchTagsLoaded = false
        let observation = ValueObservation.tracking { db in
            try TagRecord.order(Column("name").asc).fetchAll(db)
        }
        allTagsObservation = observation.start(
            in: dbQueue,
            onError: { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          self.tagObservationGeneration == generation else { return }
                    self.areSearchTagsLoaded = true
                }
            },
            onChange: { [weak self] tags in
                Task { @MainActor in
                    guard let self,
                          self.tagObservationGeneration == generation else { return }
                    self.allTags = tags
                    self.allAvailableTags = tags.map { TagInfo(name: $0.name, colorHex: $0.colorHex) }
                    self.areSearchTagsLoaded = true
                }
            }
        )
    }

    private func startProjectOverviewObservation(dbQueue: DatabaseQueue, workspaceId: UUID) {
        allProjectsObservation?.cancel()
        let observationGeneration = projectCatalogObservationTracker.beginObservation()
        isProjectCatalogLoaded = false
        projectCatalogLoadFailed = false
        let observation = ValueObservation.tracking { db in
            let projectRecords = try ProjectRecord.fetchResolvedAll(workspaceId: workspaceId, in: db)
            let aggregateRows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    projects.id AS projectId,
                    COUNT(meetings.id) AS meetingCount,
                    MAX(COALESCE(meetings.recordingStartedAt, meetings.createdAt)) AS latestMeetingDate
                FROM projects
                LEFT JOIN meetings ON meetings.projectId = projects.id
                WHERE projects.workspace_id = ?
                GROUP BY projects.id
                """,
                arguments: [workspaceId]
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
                    icon: project.icon, color: project.color,
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
                          self.currentWorkspace?.id == workspaceId,
                          self.projectCatalogObservationTracker.isCurrent(observationGeneration) else { return }
                    self.isProjectCatalogLoaded = true
                    self.projectCatalogLoadFailed = true
                }
            },
            onChange: { [weak self] projects in
                Task { @MainActor in
                    guard let self,
                          self.currentWorkspace?.id == workspaceId,
                          self.projectCatalogObservationTracker.isCurrent(observationGeneration) else { return }
                    MainWindowNavigation.shared.updateProjectAppearances(projects, workspaceId: workspaceId)
                    self.allProjectItems = projects
                    self.isProjectCatalogLoaded = true
                    self.projectCatalogLoadFailed = false
                    do {
                        try await MainWindowNavigation.shared.migrateProjectAppearances(workspaceId: workspaceId, dbQueue: dbQueue)
                    } catch {
                        sidebarViewModelLogger.error("Project appearance migration failed; retained legacy settings")
                    }
                }
            }
        )
    }

    private func startInstructionsObservation(dbQueue: DatabaseQueue, workspaceId: UUID) {
        let observation = ValueObservation.tracking { db in
            try InstructionRecord
                .filter(Column("workspace_id") == workspaceId)
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
        guard let workspace = currentWorkspace,
              let meetingRepository else { return nil }

        do {
            let instruction = try meetingRepository.createInstruction(
                workspaceId: workspace.id,
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
        guard let dbQueue, let workspace = currentWorkspace else { return }
        startProjectOverviewObservation(dbQueue: dbQueue, workspaceId: workspace.id)
    }

    func createProject(
        name: String,
        parentProjectId: UUID?,
        projectType: ProjectType? = nil,
        description: String = "",
        appearance: ProjectAppearance? = nil
    ) -> ProjectRecord? {
        guard canEditCurrentWorkspace, let projectWorkspaceService else { return nil }
        do {
            let project = try projectWorkspaceService.createProject(
                name: name,
                parentProjectId: parentProjectId,
                projectType: projectType,
                description: description,
                appearance: appearance
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
        guard canEditCurrentWorkspace, let projectWorkspaceService else { return nil }
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
        guard canEditCurrentWorkspace, let projectWorkspaceService else { return nil }
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
        guard canEditCurrentWorkspace, let projectWorkspaceService else { return nil }
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
        expectedRevision: Int,
        appearance: ProjectAppearance? = nil
    ) async -> ProjectRecord? {
        guard canEditCurrentWorkspace, let projectWorkspaceService else { return nil }
        do {
            let project = try await Task.detached(priority: .userInitiated) {
                try projectWorkspaceService.updateProject(
                    id: id,
                    name: name,
                    parentProjectId: parentProjectId,
                    projectType: projectType,
                    description: description,
                    expectedRevision: expectedRevision,
                    appearance: appearance
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
        guard canEditCurrentWorkspace, let projectWorkspaceService else { return false }
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
    func fetchOrCreateProject(name: String) -> (record: ProjectRecord, url: URL?)? {
        guard canEditCurrentWorkspace,
              let workspace = currentWorkspace,
              let projectWorkspaceService else { return nil }

        do {
            let record = try projectWorkspaceService.fetchOrCreateRootProject(name: name)
            let projectURL = workspace.url?.appending(path: record.path, directoryHint: .isDirectory)
            return (record, projectURL)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
