import Foundation
import GRDB
import Observation

/// サイドバーの状態管理。Vault 内のミーティング一覧と設定画面で使う補助データを監視する。
@Observable
@MainActor
final class SidebarViewModel {

    // MARK: - Observed State

    /// 現在の vault に属する全 project のフラット一覧。
    var flatProjects: [FlatProjectRow] = []
    /// SwiftUI の `List(selection:)` と直結するミーティング選択。
    var selectedMeetingIds: Set<UUID> = []
    /// 現在の vault に属する全 meeting の一覧。
    var allMeetings: [MeetingOverviewItem] = []
    private(set) var isMeetingCatalogLoaded = false
    /// 現在の vault に属する全 project の集約一覧。
    var allProjectItems: [ProjectOverviewItem] = []
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

    @ObservationIgnored private(set) var appDatabase: AppDatabaseManager?
    var currentVault: VaultRecord? { AppSettings.shared.currentVault }
    var dbQueue: DatabaseQueue? { appDatabase?.dbQueue }

    @ObservationIgnored private var meetingRepository: MeetingRepository?
    @ObservationIgnored private var projectWorkspaceService: ProjectWorkspaceService?
    @ObservationIgnored private var fileWatcher: TranscriptFileWatcher?
    @ObservationIgnored private var allMeetingsObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var allTagsObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var allProjectsObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var instructionsObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var projectObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var vaultObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var vaultSyncService: VaultSyncService?

    /// プロジェクト名から vault 内の URL を返す。
    func projectURL(for name: String) -> URL {
        currentVault!.url.appendingPathComponent(name, isDirectory: true)
    }

    /// 保管庫の最終オープン日時を更新する。
    func updateVaultLastOpened(_ id: UUID) {
        try? meetingRepository?.updateVaultLastOpened(id: id)
    }

    /// アプリ起動時に AppDatabaseManager と保管庫を設定する。
    /// 呼び出し前に AppSettings.shared.currentVault を設定しておくこと。
    func setAppDatabase(_ database: AppDatabaseManager?) {
        appDatabase = database
        meetingRepository = database.map { MeetingRepository(dbQueue: $0.dbQueue) }
        projectWorkspaceService = nil

        vaultSyncService?.stopMonitoring()
        projectObservation?.cancel()
        vaultObservation?.cancel()
        allMeetingsObservation?.cancel()
        allTagsObservation?.cancel()
        allProjectsObservation?.cancel()
        instructionsObservation?.cancel()
        fileWatcher?.stopMonitoring()

        vaultSyncService = nil
        fileWatcher = nil
        flatProjects.removeAll()
        allMeetings.removeAll()
        isMeetingCatalogLoaded = false
        allProjectItems.removeAll()
        allInstructions.removeAll()
        allTags.removeAll()
        allAvailableTags.removeAll()
        selectedInstruction = nil
        clearMeetingSelection()

        guard let dbQueue = database?.dbQueue else {
            allVaults.removeAll()
            AppSettings.shared.selectedInstructionID = nil
            return
        }

        startVaultObservation(dbQueue: dbQueue)

        guard let vault = currentVault else {
            AppSettings.shared.selectedInstructionID = nil
            return
        }

        let vaultURL = vault.url
        let vaultId = vault.id
        if let meetingRepository {
            projectWorkspaceService = ProjectWorkspaceService(repository: meetingRepository, vault: vault)
        }

        let syncService = VaultSyncService(vaultURL: vaultURL, dbQueue: dbQueue, vaultId: vaultId)
        vaultSyncService = syncService
        Task.detached(priority: .userInitiated) {
            syncService.performInitialSync()
        }
        syncService.startMonitoring()

        let watcher = TranscriptFileWatcher(dbQueue: dbQueue, vaultURL: vaultURL)
        watcher.startMonitoring()
        fileWatcher = watcher

        startProjectObservation(dbQueue: dbQueue, vaultId: vaultId)
        startAllMeetingsObservation(dbQueue: dbQueue, vaultId: vaultId)
        startTagsObservation(dbQueue: dbQueue)
        startProjectOverviewObservation(dbQueue: dbQueue, vaultId: vaultId)
        startInstructionsObservation(dbQueue: dbQueue, vaultId: vaultId)
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
            try ProjectRecord
                .filter(Column("vaultId") == vaultId)
                .order(Column("name").asc)
                .fetchAll(db)
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

    private func startAllMeetingsObservation(dbQueue: DatabaseQueue, vaultId: UUID) {
        let observation = ValueObservation.tracking { db in
            try MeetingOverviewItem.fetchAll(
                db,
                sql: """
                SELECT
                    meetings.id AS meetingId,
                    meetings.vaultId AS vaultId,
                    meetings.projectId AS projectId,
                    projects.name AS projectName,
                    meetings.name AS meetingName,
                    meetings.description AS meetingDescription,
                    meetings.status AS status,
                    meetings.duration AS duration,
                    meetings.createdAt AS createdAt,
                    calendar_events.title AS calendarEventTitle,
                    calendar_events.description AS calendarEventDescription,
                    calendar_events.start AS calendarEventStart,
                    calendar_events.end AS calendarEventEnd,
                    calendar_events.is_all_day AS calendarEventIsAllDay,
                    EXISTS(SELECT 1 FROM summaries WHERE summaries.meetingId = meetings.id) AS hasSummary,
                    COUNT(segments.id) AS segmentCount,
                    (
                        SELECT preview.text
                        FROM transcript_segments AS preview
                        WHERE preview.meetingId = meetings.id
                        ORDER BY preview.startTime DESC
                        LIMIT 1
                    ) AS latestSegmentText,
                    (SELECT GROUP_CONCAT(t.name || char(30) || t.colorHex, char(31))
                     FROM meeting_tags mt
                     INNER JOIN tags t ON t.id = mt.tagId
                     WHERE mt.meetingId = meetings.id) AS tags
                FROM meetings
                LEFT JOIN projects ON projects.id = meetings.projectId
                LEFT JOIN calendar_events
                  ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
                 AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
                LEFT JOIN transcript_segments AS segments ON segments.meetingId = meetings.id
                WHERE meetings.vaultId = ?
                GROUP BY meetings.id
                ORDER BY meetings.createdAt DESC, meetings.id DESC
                """,
                arguments: [vaultId]
            )
        }
        allMeetingsObservation = observation.start(
            in: dbQueue,
            onError: { _ in },
            onChange: { [weak self] meetings in
                Task { @MainActor in
                    guard let self, self.currentVault?.id == vaultId else { return }
                    // 挿入前に計算された古いスナップショットが選択直後に届くことがあるため、
                    // 「スナップショットに無い ID」ではなく「前回から消えた ID」だけを選択から外す。
                    let removedIds = Set(self.allMeetings.map(\.meetingId))
                        .subtracting(meetings.map(\.meetingId))
                    self.allMeetings = meetings
                    self.isMeetingCatalogLoaded = true
                    if !removedIds.isEmpty {
                        self.selectedMeetingIds.subtract(removedIds)
                    }
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
        let observation = ValueObservation.tracking { db in
            let projects = try ProjectOverviewItem.fetchAll(
                db,
                sql: """
                SELECT
                    projects.id AS projectId,
                    projects.name AS projectName,
                    projects.description AS projectDescription,
                    projects.createdAt AS createdAt,
                    projects.missingOnDisk AS missingOnDisk,
                    COUNT(meetings.id) AS meetingCount,
                    MAX(meetings.createdAt) AS latestMeetingDate
                FROM projects
                LEFT JOIN meetings ON meetings.projectId = projects.id
                WHERE projects.vaultId = ?
                GROUP BY projects.id
                """,
                arguments: [vaultId]
            )
            return projects.sorted { lhs, rhs in
                let comparison = lhs.projectName.localizedStandardCompare(rhs.projectName)
                if comparison == .orderedSame {
                    return lhs.projectId.uuidString < rhs.projectId.uuidString
                }
                return comparison == .orderedAscending
            }
        }
        allProjectsObservation = observation.start(
            in: dbQueue,
            onError: { _ in },
            onChange: { [weak self] projects in
                Task { @MainActor in
                    guard let self else { return }
                    self.allProjectItems = projects
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

                    if let selectedInstructionID = AppSettings.shared.selectedInstructionID,
                       !instructions.contains(where: { $0.id == selectedInstructionID }) {
                        AppSettings.shared.selectedInstructionID = nil
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
        AppSettings.shared.selectedInstructionID = instructionID
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
            if AppSettings.shared.selectedInstructionID == id {
                AppSettings.shared.selectedInstructionID = nil
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

    func createProject(leafName: String, parentProjectId: UUID?) -> ProjectRecord? {
        guard let projectWorkspaceService else { return nil }
        do {
            let project = try projectWorkspaceService.createProject(
                leafName: leafName,
                parentProjectId: parentProjectId
            )
            lastError = nil
            return project
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func renameProject(id: UUID, newLeafName: String) -> ProjectRecord? {
        guard let projectWorkspaceService else { return nil }
        do {
            let project = try projectWorkspaceService.renameProject(id: id, newLeafName: newLeafName)
            lastError = nil
            return project
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func deleteProjectHierarchy(id: UUID, meetingDisposition: ProjectMeetingDisposition) async -> Bool {
        guard let projectWorkspaceService else { return false }
        do {
            try await projectWorkspaceService.deleteProjectHierarchy(
                id: id,
                meetingDisposition: meetingDisposition
            )
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// プロジェクトを取得または作成し、対応するフォルダ URL を返す。
    func fetchOrCreateProject(name: String) -> (record: ProjectRecord, url: URL)? {
        guard let vault = currentVault,
              let repository = meetingRepository else { return nil }

        let projectURL = vault.url.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: projectURL,
                withIntermediateDirectories: true
            )
            let record = try repository.fetchOrCreateProject(name: name, vaultId: vault.id)
            return (record, projectURL)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func updateProjectDescription(id: UUID, description: String) -> Bool {
        guard let meetingRepository else { return false }
        do {
            try meetingRepository.updateProjectDescription(id: id, description: description)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func projectDescription(id: UUID) -> String? {
        do {
            return try meetingRepository?.fetchProject(id: id)?.description
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Meeting Management

    func renameMeeting(id: UUID, newName: String) {
        try? meetingRepository?.renameMeeting(id: id, newName: newName)
    }

    private static let tagColorPalette = [
        "#FF6B6B", "#4ECDC4", "#45B7D1", "#96CEB4",
        "#FFEAA7", "#DDA0DD", "#98D8C8", "#F7DC6F",
        "#BB8FCE", "#85C1E9",
    ]

    func addTagToMeeting(id: UUID, tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let colorHex = Self.tagColorPalette.randomElement() ?? "#808080"
        try? meetingRepository?.addTag(name: trimmed, toMeetingId: id, colorHex: colorHex)
    }

    func removeTagFromMeeting(id: UUID, tag: String) {
        try? meetingRepository?.removeTag(name: tag, fromMeetingId: id)
    }

    func deleteMeeting(id: UUID) {
        guard let meetingRepository else { return }
        Task {
            do {
                try await meetingRepository.deleteMeetingSafely(id: id)
                selectedMeetingIds.remove(id)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func deleteMeetings(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        guard let meetingRepository else { return }
        Task {
            do {
                try await meetingRepository.deleteMeetingsSafely(ids: ids)
                selectedMeetingIds.subtract(ids)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func moveMeeting(id: UUID, toProjectId: UUID?) {
        guard let repository = meetingRepository else { return }
        do {
            try repository.moveMeeting(id: id, toProjectId: toProjectId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func moveMeetings(ids: Set<UUID>, toProjectId: UUID?) {
        guard let repository = meetingRepository, !ids.isEmpty else { return }
        do {
            try repository.moveMeetings(ids: ids, toProjectId: toProjectId)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
