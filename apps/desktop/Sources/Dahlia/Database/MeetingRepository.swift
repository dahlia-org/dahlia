import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

enum DahliaAccountWorkspaceDisposition: Equatable, Sendable {
    case deleteLocalCopies
    case moveToLocalAccount
}

/// ミーティング・セグメント・プロジェクト・ワークスペースの DB クエリを集約するリポジトリ。
@MainActor
// Query methods share one MainActor-isolated database boundary.
// swiftlint:disable:next type_body_length
final class MeetingRepository {
    struct MeetingMoveCandidate {
        let meetingId: UUID
        let projectId: UUID?
        let hasWorkspaceExport: Bool
        let workspaceRelativePath: String?
    }

    struct MeetingWorkspaceExportUpdate {
        let meetingId: UUID
        let relativePath: String?
    }

    nonisolated static func updateWorkspaceExports(
        _ updates: [MeetingWorkspaceExportUpdate],
        forMeetingIds meetingIds: Set<UUID>,
        in db: Database
    ) throws {
        let existingRecords = try SummaryExportRecord
            .filter(meetingIds.contains(Column("meetingId")))
            .filter(Column("type") == SummaryExportType.workspace)
            .fetchAll(db)
        let existingByMeetingId = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.meetingId, $0) })
        let updatedAt = Date.now

        for update in updates where meetingIds.contains(update.meetingId) {
            guard let url = update.relativePath.flatMap(SummaryExportRecord.workspaceURL(relativePath:)) else {
                if let existing = existingByMeetingId[update.meetingId] {
                    _ = try existing.delete(db)
                }
                continue
            }
            try SummaryExportRecord(
                meetingId: update.meetingId,
                type: .workspace,
                url: url,
                createdAt: existingByMeetingId[update.meetingId]?.createdAt ?? updatedAt,
                updatedAt: updatedAt
            ).save(db)
        }
    }

    private nonisolated static let generatedSummaryTagColorHex = "#808080"

    nonisolated let dbQueue: DatabaseQueue

    nonisolated init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Workspaces

    nonisolated func fetchLatestLocalAccountWorkspace() async throws -> WorkspaceRecord? {
        try await dbQueue.read { db in
            try WorkspaceRecord.filter(Column("accountConnectionId") == nil)
                .order(Column("lastOpenedAt").desc, Column("id"))
                .fetchOne(db)
        }
    }

    /// 全ワークスペースを最終オープン日時の降順で取得する。
    nonisolated func fetchAllWorkspaces() throws -> [WorkspaceRecord] {
        try dbQueue.read { db in
            try WorkspaceRecord.order(Column("lastOpenedAt").desc).fetchAll(db)
        }
    }

    /// UI をブロックせず、全ワークスペースを最終オープン日時の降順で取得する。
    nonisolated func fetchAllWorkspacesAsync() async throws -> [WorkspaceRecord] {
        try await dbQueue.read { db in
            try WorkspaceRecord.order(Column("lastOpenedAt").desc).fetchAll(db)
        }
    }

    /// 最後にオープンしたワークスペースを取得する。
    func fetchLastOpenedWorkspace() throws -> WorkspaceRecord? {
        try dbQueue.read { db in
            try WorkspaceRecord
                .filter(Column("lastOpenedAt") != Date.distantPast)
                .order(Column("lastOpenedAt").desc)
                .fetchOne(db)
        }
    }

    /// ワークスペースを登録する。
    nonisolated func insertWorkspace(_ workspace: WorkspaceRecord) throws {
        try dbQueue.write { db in
            try workspace.insert(db)
        }
    }

    /// UI をブロックせず、ワークスペースを登録する。
    nonisolated func insertWorkspaceAsync(_ workspace: WorkspaceRecord) async throws {
        try await dbQueue.write { db in
            try workspace.insert(db)
        }
    }

    nonisolated func insertCloudWorkspaceAsync(_ workspace: WorkspaceRecord, revision: Int) async throws {
        try await dbQueue.write { db in
            try workspace.insert(db)
            try db.execute(
                sql: """
                INSERT INTO sync_entity_state(workspace_id, entity, entityId, confirmedRevision)
                VALUES (?, 'workspace', ?, ?)
                """,
                arguments: [workspace.id, workspace.id, revision]
            )
        }
    }

    /// Discovery creates a working copy, never a local upload or an implicit account transfer.
    nonisolated static func registerDiscoveredCloudWorkspaces(
        _ cloudWorkspaces: [CloudWorkspaceRecord],
        connection: DahliaAccountConnectionRecord,
        dbQueue: DatabaseQueue
    ) async throws -> Bool {
        try await dbQueue.write { db in
            try Task.checkCancellation()
            guard let current = try DahliaAccountConnectionRecord.fetchOne(db, key: connection.id),
                  current.origin == connection.origin, current.clientID == connection.clientID else { return false }
            var changed = false
            for cloud in cloudWorkspaces where cloud.connectionId == connection.id {
                if var existing = try WorkspaceRecord.fetchOne(db, key: cloud.workspaceId) {
                    guard existing.accountConnectionId == connection.id,
                          existing.syncConfirmedConnectionId == connection.id else { continue }
                    guard existing.organizationId == cloud.organizationId else { throw SyncTransactionQueueError.invalidReceipt }
                    guard existing.syncRole != cloud.role else { continue }
                    existing.syncRole = cloud.role
                    try existing.update(db)
                    changed = true
                    continue
                }
                var workspace = WorkspaceRecord(
                    id: cloud.workspaceId, path: nil, icon: cloud.icon, color: cloud.color,
                    name: cloud.name, createdAt: cloud.createdAt, lastOpenedAt: .distantPast
                )
                workspace.accountConnectionId = connection.id
                workspace.syncConfirmedConnectionId = connection.id
                workspace.syncRole = cloud.role
                workspace.organizationId = cloud.organizationId
                try workspace.insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(workspace_id, entity, entityId, confirmedRevision) VALUES (?, 'workspace', ?, ?)",
                    arguments: [workspace.id, workspace.id, cloud.revision]
                )
                changed = true
            }
            return changed
        }
    }

    /// ワークスペースの表示名を更新する。
    nonisolated func updateWorkspaceName(id: UUID, name: String, appearance: ProjectAppearance? = nil) async throws -> WorkspaceRecord? {
        try await dbQueue.write { db in
            guard var workspace = try WorkspaceRecord.fetchOne(db, key: id) else { return nil }
            guard workspace.allowsWorkspaceManagement else { throw SyncTransactionQueueError.readOnlyWorkspace }
            workspace.name = name
            if let appearance { workspace.appearance = appearance }
            try workspace.update(db)
            try SyncTransactionRecorder.record(
                workspaceId: id,
                operations: [SyncInitialSnapshotBuilder.workspaceOperation(workspace, action: .update)],
                in: db
            )
            return workspace
        }
    }

    /// Device-local export folder. This never produces a Server transaction.
    nonisolated func updateWorkspacePath(id: UUID, path: String?) async throws -> WorkspaceRecord? {
        try await dbQueue.write { db in
            guard var workspace = try WorkspaceRecord.fetchOne(db, key: id) else { return nil }
            guard workspace.path != path else { return workspace }
            workspace.path = path
            try workspace.update(db)
            try db.execute(
                sql: """
                DELETE FROM summary_exports
                WHERE type = ?
                  AND meetingId IN (SELECT id FROM meetings WHERE workspace_id = ?)
                """,
                arguments: [SummaryExportType.workspace.rawValue, id]
            )
            return workspace
        }
    }

    nonisolated func updateWorkspaceAISettings(_ settings: WorkspaceAISettingsSnapshot) async throws -> WorkspaceRecord? {
        try await dbQueue.write { db in
            guard var workspace = try WorkspaceRecord.fetchOne(db, key: settings.workspaceID) else { return nil }
            settings.applyAISettings(to: &workspace)
            try workspace.update(db)
            return workspace
        }
    }

    nonisolated func adoptWorkspaceForServerSync(
        id: UUID,
        connectionID: UUID,
        serverWorkspace: CloudWorkspaceRecord,
        expectedChanges: Int,
        screenshotContent: ScreenshotContentProvider = .shared
    ) async throws -> WorkspaceRecord? {
        guard serverWorkspace.workspaceId == id, serverWorkspace.connectionId == connectionID, serverWorkspace.role == "admin" else {
            throw LocalWorkspaceImportError.unavailable
        }
        screenshotContent.retainOriginals(workspaceIds: [id], dbQueue: dbQueue)
        defer { screenshotContent.releaseOriginals(workspaceIds: [id], dbQueue: dbQueue) }
        let files = try await screenshotContent.prepareAccountTransfer(workspaceId: id, connectionId: connectionID, dbQueue: dbQueue)
        return try await dbQueue.write { db in
            guard db.totalChangesCount == expectedChanges,
                  var workspace = try WorkspaceRecord.fetchOne(db, key: id), workspace.accountConnectionId == nil,
                  try !RecordingSessionRecord.hasActiveRecording(workspaceId: id, in: db),
                  try !SyncTransactionQueue.hasPending(workspaceId: id, in: db) else { throw LocalWorkspaceImportError.changed }
            try ScreenshotContentProvider.installTransfers(files, workspaceId: id, in: db)
            workspace.accountConnectionId = connectionID
            workspace.organizationId = serverWorkspace.organizationId
            workspace.syncRole = serverWorkspace.role
            workspace.syncConfirmedConnectionId = connectionID
            try workspace.update(db)
            try db.execute(
                sql: "INSERT INTO sync_entity_state(workspace_id, entity, entityId, confirmedRevision) VALUES (?, 'workspace', ?, ?)",
                arguments: [id, id, serverWorkspace.revision]
            )
            var items: [WorkspaceRelocation.Item] = []
            for (entity, table) in [(SyncEntity.project, "projects"), (.meeting, "meetings"), (.file, "files")] {
                items += try UUID.fetchAll(db, sql: "SELECT id FROM \(table) WHERE workspace_id = ?", arguments: [id])
                    .map { .init(entity: entity, id: $0, workspaceId: id) }
            }
            try SyncInitialSnapshotBuilder.enqueueContents(items, workspaceId: id, in: db)
            return workspace
        }
    }

    nonisolated func acceptServerSyncVersion(workspaceId: UUID) async throws {
        try await SyncTransactionQueue.acceptServerVersion(workspaceId: workspaceId, dbQueue: dbQueue)
    }

    nonisolated func discardInvalidSyncTransaction(workspaceId: UUID) async throws {
        try await SyncTransactionQueue.discardInvalidTransaction(workspaceId: workspaceId, dbQueue: dbQueue)
    }

    nonisolated func retryInvalidSyncTransaction(workspaceId: UUID) async throws {
        try await SyncTransactionQueue.retryInvalidTransaction(workspaceId: workspaceId, dbQueue: dbQueue)
    }

    nonisolated func retryAuthorizationSync(connectionId: UUID) async throws {
        try await SyncTransactionQueue.retryAuthorizationBlocks(connectionId: connectionId, dbQueue: dbQueue)
    }

    nonisolated func reapplyLocalSyncVersion(workspaceId: UUID) async throws {
        try await SyncTransactionQueue.reapplyLocalVersion(workspaceId: workspaceId, dbQueue: dbQueue)
    }

    nonisolated func blockedSyncWorkspaceIDs() async throws -> Set<UUID> {
        try await dbQueue.read { db in
            try UUID.fetchSet(db, sql: "SELECT DISTINCT workspace_id FROM sync_transactions WHERE blockedReason IS NOT NULL")
        }
    }

    nonisolated func conflictedSyncWorkspaceIDs() async throws -> Set<UUID> {
        try await dbQueue.read { db in
            try UUID.fetchSet(db, sql: "SELECT DISTINCT workspace_id FROM sync_transactions WHERE blockedReason = 'conflict'")
        }
    }

    nonisolated func validationBlockedSyncWorkspaceIDs() async throws -> Set<UUID> {
        try await dbQueue.read { db in
            try UUID.fetchSet(db, sql: "SELECT DISTINCT workspace_id FROM sync_transactions WHERE blockedReason = 'validation'")
        }
    }

    nonisolated func backfillWorkspaceAISettings(_ settings: WorkspaceAISettingsLegacyValues) async throws {
        try await dbQueue.write { db in
            var workspaces = try WorkspaceRecord.filter(Column("aiSettingsBackfilled") == false).fetchAll(db)
            for index in workspaces.indices {
                settings.apply(to: &workspaces[index])
                workspaces[index].aiSettingsBackfilled = true
                try workspaces[index].update(db)
            }
        }
    }

    nonisolated func workspaceCountsByAccountConnectionID() async throws -> [UUID: Int] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT accountConnectionId, COUNT(*) AS workspaceCount
                FROM workspaces
                WHERE accountConnectionId IS NOT NULL
                GROUP BY accountConnectionId
                """
            )
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let connectionID: UUID = row["accountConnectionId"] else { return nil }
                let count: Int = row["workspaceCount"]
                return (connectionID, count)
            })
        }
    }

    /// ワークスペースを登録解除する（関連プロジェクト・ミーティングもカスケード削除）。
    nonisolated func deleteWorkspace(id: UUID) throws {
        try ensureWorkspaceCanBeRemoved(id: id)
        let meetingIds = try meetingIds(workspaceId: id)
        try ensureNoLiveSegmentedAudio(meetingIds: Set(meetingIds))
        let audioTargets = try BatchAudioCleanupService.deletionTargets(workspaceId: id, dbQueue: dbQueue)
        try dbQueue.writeWithoutTransaction { db in
            try db.inTransaction {
                try Self.deleteWorkspaceRows(id: id, in: db)
                return .rollback
            }
        }
        try BatchAudioCleanupService.deleteFiles(audioTargets)
        try dbQueue.write { db in
            try Self.deleteWorkspaceRows(id: id, in: db)
        }
    }

    private nonisolated static func deleteWorkspaceRows(id: UUID, in db: Database) throws {
        if try WorkspaceRecord.fetchOne(db, key: id)?.syncRole == "viewer" {
            try SyncTransactionQueue.discard(workspaceId: id, in: db)
        }
        let projects = try ProjectRecord.fetchResolvedAll(workspaceId: id, in: db)
            .sorted {
                $0.path.split(separator: "/").count > $1.path.split(separator: "/").count
            }
        for project in projects {
            _ = try ProjectRecord.deleteOne(db, key: project.id)
        }
        _ = try WorkspaceRecord.deleteOne(db, key: id)
    }

    nonisolated func deleteWorkspaceSafely(
        id: UUID,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) async throws {
        try ensureWorkspaceCanBeRemoved(id: id)
        let ids = try meetingIds(workspaceId: id)
        try await prepareSegmentedAudioForDeletion(
            meetingIds: Set(ids),
            managedRootURL: managedRootURL
        )
        try deleteWorkspace(id: id)
    }

    nonisolated func resolveWorkspacesForSignOut(
        connectionID: UUID,
        disposition: DahliaAccountWorkspaceDisposition,
        managedRootURL: URL = BatchAudioStorage.managedRootURL,
        screenshotContent: ScreenshotContentProvider = .shared,
        textContent: MeetingContentProvider = .shared
    ) async throws {
        let workspaceIds = try await dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT id FROM workspaces WHERE accountConnectionId = ? ORDER BY id",
                arguments: [connectionID]
            )
        }
        guard !workspaceIds.isEmpty else { return }

        if disposition == .moveToLocalAccount {
            screenshotContent.retainOriginals(workspaceIds: workspaceIds, dbQueue: dbQueue)
            defer { screenshotContent.releaseOriginals(workspaceIds: workspaceIds, dbQueue: dbQueue) }
            let textSources = try await textContent.prepareAccountTransfer(workspaceIds: workspaceIds, connectionId: connectionID, dbQueue: dbQueue)
            defer { Task { await textContent.releaseAccountTransfer(workspaceIds: workspaceIds, dbQueue: dbQueue) } }
            var prepared: [UUID: [FileTransfer]] = [:]
            for workspaceId in workspaceIds {
                prepared[workspaceId] = try await screenshotContent.prepareAccountTransfer(
                    workspaceId: workspaceId,
                    connectionId: nil,
                    dbQueue: dbQueue
                )
            }
            let transfers = prepared
            try await textContent.validateAccountTransfer(textSources, dbQueue: dbQueue)
            try await dbQueue.write { db in
                guard try Set(UUID.fetchAll(db, sql: "SELECT id FROM workspaces WHERE accountConnectionId = ?", arguments: [connectionID])) ==
                    Set(workspaceIds)
                else { throw TextContentError.changed }
                for workspaceId in workspaceIds {
                    guard try WorkspaceRecord.fetchOne(db, key: workspaceId)?.accountConnectionId == connectionID
                    else { throw ScreenshotContentError.authorizationRequired }
                    guard try MeetingContentProvider.TransferSource.read(workspaceId: workspaceId, in: db) == textSources[workspaceId]
                    else { throw TextContentError.changed }
                    try TextContentStore.requireWorkspaceComplete(workspaceId: workspaceId, in: db)
                    try ScreenshotContentProvider.installTransfers(transfers[workspaceId, default: []], workspaceId: workspaceId, in: db)
                }
                for workspaceId in workspaceIds {
                    try SyncTransactionQueue.discard(workspaceId: workspaceId, in: db)
                    try db.execute(sql: "DELETE FROM sync_content_state WHERE workspace_id = ?", arguments: [workspaceId])
                }
                try db.execute(
                    sql: "DELETE FROM sync_entity_state WHERE workspace_id IN (\(workspaceIds.map { _ in "?" }.joined(separator: ",")))",
                    arguments: StatementArguments(workspaceIds)
                )
                try db.execute(
                    sql: """
                    UPDATE workspaces SET accountConnectionId = NULL, syncRole = NULL, organizationId = NULL,
                        syncConfirmedConnectionId = NULL, syncPullCursor = NULL,
                        syncLastCommittedCursor = NULL
                    WHERE accountConnectionId = ?
                    """,
                    arguments: [connectionID]
                )
            }
            return
        }

        let meetingIds = try await dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT id FROM meetings WHERE workspace_id IN (\(workspaceIds.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(workspaceIds)
            )
        }
        let hasActiveRecording = if meetingIds.isEmpty {
            false
        } else {
            try await dbQueue.read { db in
                try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM recording_sessions
                        WHERE meetingId IN (\(meetingIds.map { _ in "?" }.joined(separator: ",")))
                          AND endedAt IS NULL
                    )
                    """,
                    arguments: StatementArguments(meetingIds)
                ) ?? false
            }
        }
        guard !hasActiveRecording else { throw RecordingAudioStoreError.invalidState }
        try ensureNoLiveSegmentedAudio(meetingIds: Set(meetingIds))
        try await prepareSegmentedAudioForDeletion(meetingIds: Set(meetingIds), managedRootURL: managedRootURL)
        let audioTargets = try workspaceIds.flatMap {
            try BatchAudioCleanupService.deletionTargets(workspaceId: $0, dbQueue: dbQueue)
        }
        try await dbQueue.writeWithoutTransaction { db in
            try db.inTransaction {
                for workspaceId in workspaceIds {
                    try SyncTransactionQueue.discard(workspaceId: workspaceId, in: db)
                    try Self.deleteWorkspaceRows(id: workspaceId, in: db)
                }
                return .rollback
            }
        }
        try BatchAudioCleanupService.deleteFiles(audioTargets)
        try await dbQueue.write { db in
            let placeholders = workspaceIds.map { _ in "?" }.joined(separator: ",")
            let arguments = StatementArguments(workspaceIds)
            let hasActiveRecording = try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (
                    SELECT 1 FROM recording_sessions
                    JOIN meetings ON meetings.id = recording_sessions.meetingId
                    WHERE meetings.workspace_id IN (\(placeholders))
                      AND recording_sessions.endedAt IS NULL
                )
                """,
                arguments: arguments
            ) ?? false
            let hasLiveAudio = try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (
                    SELECT 1 FROM recording_audio_segments
                    JOIN recording_sessions ON recording_sessions.id = recording_audio_segments.recordingSessionId
                    JOIN meetings ON meetings.id = recording_sessions.meetingId
                    WHERE meetings.workspace_id IN (\(placeholders))
                      AND recording_audio_segments.state != ?
                )
                """,
                arguments: arguments + [RecordingAudioSegmentState.purged.rawValue]
            ) ?? false
            guard !hasActiveRecording, !hasLiveAudio else { throw RecordingAudioStoreError.invalidState }
            for workspaceId in workspaceIds {
                try SyncTransactionQueue.discard(workspaceId: workspaceId, in: db)
                try Self.deleteWorkspaceRows(id: workspaceId, in: db)
            }
        }
    }

    private nonisolated func ensureWorkspaceCanBeRemoved(id: UUID) throws {
        if try dbQueue.read({ db in
            try WorkspaceRecord.fetchOne(db, key: id)?.requiresServerDeletionBeforeRemoval == true
        }) {
            throw WorkspaceDeletionError.serverCopyExists
        }
    }

    /// UI をブロックせず、ワークスペースの最終オープン日時を更新する。
    nonisolated func updateWorkspaceLastOpened(id: UUID) async throws -> WorkspaceRecord? {
        try await dbQueue.write { db in
            guard var record = try WorkspaceRecord.fetchOne(db, key: id) else { return nil }
            record.lastOpenedAt = .now
            try record.update(db)
            return record
        }
    }

    // MARK: - Instructions

    func fetchInstructions(workspaceId: UUID) throws -> [InstructionRecord] {
        try dbQueue.read { db in
            try InstructionRecord
                .filter(Column("workspace_id") == workspaceId)
                .order(Column("name").asc)
                .fetchAll(db)
        }
    }

    func fetchInstruction(id: UUID) throws -> InstructionRecord? {
        try dbQueue.read { db in
            try InstructionRecord.fetchOne(db, key: id)
        }
    }

    func createInstruction(workspaceId: UUID, name: String, content: String) throws -> InstructionRecord {
        try dbQueue.write { db in
            let now = Date()
            let record = InstructionRecord(
                id: .v7(),
                workspaceId: workspaceId,
                name: name,
                content: content,
                createdAt: now,
                updatedAt: now
            )
            try record.insert(db)
            return record
        }
    }

    func updateInstruction(id: UUID, name: String, content: String) throws {
        try dbQueue.write { db in
            guard var record = try InstructionRecord.fetchOne(db, key: id) else { return }
            record.name = name
            record.content = content
            record.updatedAt = Date()
            try record.update(db)
        }
    }

    func deleteInstruction(id: UUID) throws {
        try dbQueue.write { db in
            _ = try InstructionRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - Meetings

    nonisolated func fetchMeeting(id: UUID) throws -> MeetingRecord? {
        try dbQueue.read { db in
            try MeetingRecord.fetchOne(db, key: id)
        }
    }

    func renameMeeting(id: UUID, newName: String) throws {
        try dbQueue.write { db in
            if var record = try MeetingRecord.fetchOne(db, key: id) {
                record.name = newName
                record.updatedAt = .now
                try record.update(db)
                try SyncTransactionRecorder.record(
                    workspaceId: record.workspaceId,
                    operations: [SyncInitialSnapshotBuilder.meetingOperation(record, action: .update, in: db)],
                    in: db
                )
            }
        }
    }

    func deleteMeeting(id: UUID) throws {
        try ensureNoLiveSegmentedAudio(meetingIds: [id])
        let audioTargets = try BatchAudioCleanupService.deletionTargets(meetingIds: [id], dbQueue: dbQueue)
        try BatchAudioCleanupService.deleteFiles(audioTargets)
        try dbQueue.write { db in
            guard let meeting = try MeetingRecord.fetchOne(db, key: id) else { return }
            try SyncTransactionRecorder.record(
                workspaceId: meeting.workspaceId,
                operations: [SyncOperationDraft(entity: .meeting, action: .delete, entityId: id)],
                in: db
            )
            _ = try MeetingRecord.deleteOne(db, key: id)
        }
    }

    func deleteMeetingSafely(
        id: UUID,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) async throws {
        try await prepareSegmentedAudioForDeletion(meetingIds: [id], managedRootURL: managedRootURL)
        try deleteMeeting(id: id)
    }

    /// 復旧不能なバッチ録音を明示的に破棄し、要約生成のブロック対象から外す。
    @discardableResult
    func discardFailedBatchSessionSafely(
        id: UUID,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) async throws -> Bool {
        try await BatchTranscriptionDiscardService.discardFailedSessionSafely(
            id: id,
            dbQueue: dbQueue,
            managedRootURL: managedRootURL
        )
    }

    /// 未確認または失敗したバッチ録音を、音声ファイルと部分結果を含めて明示的に破棄する。
    @discardableResult
    func discardUnprocessedBatchSessionSafely(
        id: UUID,
        expectedWorkspaceId: UUID,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) async throws -> Bool {
        try await BatchTranscriptionDiscardService.discardUnprocessedSessionSafely(
            id: id,
            expectedWorkspaceId: expectedWorkspaceId,
            dbQueue: dbQueue,
            managedRootURL: managedRootURL
        )
    }

    /// 複数のミーティングを一括削除する。
    func deleteMeetings(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try ensureNoLiveSegmentedAudio(meetingIds: ids)
        let audioTargets = try BatchAudioCleanupService.deletionTargets(meetingIds: ids, dbQueue: dbQueue)
        try BatchAudioCleanupService.deleteFiles(audioTargets)
        try dbQueue.write { db in
            let meetings = try MeetingRecord.filter(ids.contains(Column("id"))).fetchAll(db)
            for (workspaceId, workspaceMeetings) in Dictionary(grouping: meetings, by: \.workspaceId) {
                try SyncTransactionRecorder.recordBatches(
                    workspaceId: workspaceId,
                    operations: workspaceMeetings.map {
                        SyncOperationDraft(entity: .meeting, action: .delete, entityId: $0.id)
                    },
                    in: db
                )
            }
            _ = try MeetingRecord.filter(ids.contains(Column("id"))).deleteAll(db)
        }
    }

    func deleteMeetingsSafely(
        ids: Set<UUID>,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) async throws {
        guard !ids.isEmpty else { return }
        try await prepareSegmentedAudioForDeletion(meetingIds: ids, managedRootURL: managedRootURL)
        try deleteMeetings(ids: ids)
    }

    nonisolated func fetchMeetingMoveCandidates(ids: Set<UUID>, workspaceId: UUID) throws -> [MeetingMoveCandidate] {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { db in
            let meetings = try MeetingRecord
                .filter(ids.contains(Column("id")))
                .filter(Column("workspace_id") == workspaceId)
                .fetchAll(db)
            let workspaceExports = try SummaryExportRecord
                .filter(ids.contains(Column("meetingId")))
                .filter(Column("type") == SummaryExportType.workspace)
                .fetchAll(db)
            let workspaceExportsByMeetingId = Dictionary(uniqueKeysWithValues: workspaceExports.map { ($0.meetingId, $0) })

            return meetings.map { meeting in
                let workspaceExport = workspaceExportsByMeetingId[meeting.id]
                return MeetingMoveCandidate(
                    meetingId: meeting.id,
                    projectId: meeting.projectId,
                    hasWorkspaceExport: workspaceExport != nil,
                    workspaceRelativePath: workspaceExport?.workspaceRelativePath
                )
            }
        }
    }

    nonisolated func externalWorkspaceSummaryPaths(
        movingMeetingIds: Set<UUID>,
        workspaceId: UUID
    ) throws -> [String] {
        guard !movingMeetingIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            let placeholders = movingMeetingIds.map { _ in "?" }.joined(separator: ",")
            var arguments: StatementArguments = [SummaryExportType.workspace, workspaceId]
            arguments += StatementArguments(movingMeetingIds)
            let records = try SummaryExportRecord.fetchAll(
                db,
                sql: """
                SELECT summary_exports.*
                FROM summary_exports
                JOIN meetings ON meetings.id = summary_exports.meetingId
                WHERE summary_exports.type = ?
                  AND meetings.workspace_id = ?
                  AND summary_exports.meetingId NOT IN (\(placeholders))
                """,
                arguments: arguments
            )
            return records.compactMap(\.workspaceRelativePath)
        }
    }

    func commitMeetingMove(
        ids: Set<UUID>,
        toProjectId: UUID?,
        workspaceId: UUID,
        workspaceExportUpdates: [MeetingWorkspaceExportUpdate]
    ) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            if let toProjectId {
                guard let destination = try ProjectRecord.fetchOne(db, key: toProjectId),
                      destination.workspaceId == workspaceId
                else {
                    throw ProjectWorkspaceError.invalidMoveDestination
                }
            }

            _ = try MeetingRecord
                .filter(ids.contains(Column("id")))
                .filter(Column("workspace_id") == workspaceId)
                .updateAll(db, Column("projectId").set(to: toProjectId))

            let changedMeetings = try MeetingRecord
                .filter(ids.contains(Column("id")))
                .filter(Column("workspace_id") == workspaceId)
                .fetchAll(db)
            try SyncTransactionRecorder.recordBatches(
                workspaceId: workspaceId,
                operations: changedMeetings.map {
                    try SyncInitialSnapshotBuilder.meetingOperation($0, action: .update, in: db)
                },
                in: db
            )

            try Self.updateWorkspaceExports(workspaceExportUpdates, forMeetingIds: ids, in: db)
        }
    }

    nonisolated func applyGeneratedSummary(
        toMeetingId meetingId: UUID,
        document: SummaryDocument,
        tags: [String],
        expectation: SummaryGenerationExpectation? = nil
    ) throws {
        try dbQueue.write { db in
            try expectation?.validate(meetingID: meetingId, in: db)
            let processing = try expectation?.recordingSessionID.flatMap { try RecordingProcessing.load(sessionID: $0, in: db) }
            if processing?.summaryApplied == true {
                guard try SummaryBodyRecord.fetchOne(db, key: meetingId)?.document == document.databaseJSONString() else {
                    throw TextContentError.changed
                }
                return
            }
            guard var meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { return }

            let existingSummary = try SummaryContent.fetchOne(db, key: meetingId)
            let normalizedTitle = SummaryGeneratedMetadata.normalizedTitle(document.title)
            if let normalizedTitle {
                meeting.name = normalizedTitle
            }
            if let description = SummaryGeneratedMetadata.normalizedDescription(document.description) {
                meeting.description = description
            }
            meeting.updatedAt = Date()
            try meeting.update(db)

            let record = try SummaryContent(
                meetingId: meetingId,
                title: normalizedTitle ?? existingSummary?.title ?? "",
                document: document.databaseJSONString(),
                createdAt: existingSummary?.createdAt ?? Date()
            )
            try record.save(db)
            try SyncTransactionRecorder.record(
                workspaceId: meeting.workspaceId,
                operations: [
                    SyncInitialSnapshotBuilder.meetingOperation(meeting, action: .update, in: db),
                    SyncInitialSnapshotBuilder.summaryOperation(record, action: .upsert),
                ],
                in: db
            )
            _ = try SummaryExportRecord
                .filter(Column("meetingId") == meetingId)
                .deleteAll(db)

            try Self.mergeGeneratedSummaryTags(tags, meetingId: meetingId, recordEvents: true, in: db)
            if let sessionID = expectation?.recordingSessionID, var processing {
                processing.summaryApplied = true
                processing.summaryExpectation = try SummaryGenerationExpectation(
                    summaryDocument: document.databaseJSONString(), transcriptID: expectation?.transcriptID,
                    recordingSessionID: sessionID, jobID: processing.id
                )
                processing.stage = .saving
                processing.error = nil
                try processing.save(sessionID: sessionID, in: db)
            }
        }
    }

    nonisolated static func mergeGeneratedSummaryTags(
        _ tags: [String], meetingId: UUID, recordEvents: Bool, in db: Database
    ) throws {
        let tagNames = Array(Set(tags.filter { !$0.isEmpty }))
        if !tagNames.isEmpty {
            let existingTags = try TagRecord
                .filter(tagNames.contains(Column("name")))
                .fetchAll(db)
            let existingByName = Dictionary(uniqueKeysWithValues: existingTags.compactMap { tag in
                tag.id.map { (tag.name, $0) }
            })

            for name in tagNames {
                let tagId: Int64
                if let existingId = existingByName[name] {
                    tagId = existingId
                } else {
                    let newTag = TagRecord(
                        name: name,
                        colorHex: Self.generatedSummaryTagColorHex,
                        createdAt: Date()
                    )
                    try newTag.insert(db)
                    tagId = db.lastInsertedRowID
                }

                try db.execute(
                    sql: "INSERT OR IGNORE INTO meeting_tags (meetingId, tagId) VALUES (?, ?)",
                    arguments: [meetingId, tagId]
                )
                if recordEvents, db.changesCount > 0 {
                    try MeetingEventRecorder.record(.tagAdded, meetingId: meetingId, relatedId: String(tagId), in: db)
                }
            }
        }
    }

    // MARK: - Tags

    func addTag(name: String, toMeetingId meetingId: UUID, colorHex: String) throws {
        try dbQueue.write { db in
            let tagId: Int64
            if let existing = try TagRecord.filter(Column("name") == name).fetchOne(db) {
                guard let existingId = existing.id else { return }
                tagId = existingId
            } else {
                let newTag = TagRecord(name: name, colorHex: colorHex, createdAt: Date())
                try newTag.insert(db)
                tagId = db.lastInsertedRowID
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO meeting_tags (meetingId, tagId) VALUES (?, ?)",
                arguments: [meetingId, tagId]
            )
            if db.changesCount > 0 {
                try MeetingEventRecorder.record(.tagAdded, meetingId: meetingId, relatedId: String(tagId), in: db)
            }
        }
    }

    /// 孤立したタグマスタも自動削除する。
    func removeTag(name: String, fromMeetingId meetingId: UUID) throws {
        try dbQueue.write { db in
            guard let tag = try TagRecord.filter(Column("name") == name).fetchOne(db),
                  let tagId = tag.id else { return }
            let removed = try MeetingTagRecord
                .filter(Column("meetingId") == meetingId && Column("tagId") == tagId)
                .deleteAll(db)
            if removed > 0 {
                try MeetingEventRecorder.record(.tagRemoved, meetingId: meetingId, relatedId: String(tagId), in: db)
            }
            let count = try MeetingTagRecord.filter(Column("tagId") == tagId).fetchCount(db)
            if count == 0 {
                _ = try TagRecord.deleteOne(db, key: tagId)
            }
        }
    }

    func fetchTagsForMeeting(id meetingId: UUID) throws -> [TagRecord] {
        try dbQueue.read { db in
            try TagRecord.fetchAll(
                db,
                sql: """
                SELECT t.*
                FROM tags t
                INNER JOIN meeting_tags mt ON mt.tagId = t.id
                WHERE mt.meetingId = ?
                ORDER BY t.name ASC
                """,
                arguments: [meetingId]
            )
        }
    }

    // MARK: - Segments

    nonisolated func fetchSegments(forMeetingId meetingId: UUID) throws -> [TranscriptContent] {
        try dbQueue.read { db in
            try TextContentAccess.transcript(meetingId: meetingId, in: db)
        }
    }

    nonisolated func fetchTranscriptPage(
        forMeetingId meetingId: UUID,
        direction: TranscriptPageDirection,
        limit: Int
    ) throws -> TranscriptPage {
        guard limit > 0 else {
            return TranscriptPage(segments: [], hasEarlier: false, hasLater: false)
        }
        let pageLimit = min(limit, Int.max - 1)
        let fetchLimit = pageLimit + 1

        return try dbQueue.read { db in
            let records: [TranscriptContent]
            let hasEarlier: Bool
            let hasLater: Bool

            switch direction {
            case .latest:
                let fetched = try TextContentAccess.transcript(
                    meetingId: meetingId, order: .reverse, confirmedOnly: true, limit: fetchLimit, in: db
                )
                hasEarlier = fetched.count > pageLimit
                hasLater = false
                records = Array(fetched.prefix(pageLimit).reversed())

            case let .before(cursor):
                let fetched = try TextContentAccess.transcript(
                    meetingId: meetingId, order: .reverse,
                    position: .init(id: cursor.id, startTime: cursor.startTime),
                    confirmedOnly: true, limit: fetchLimit, in: db
                )
                hasEarlier = fetched.count > pageLimit
                hasLater = true
                records = Array(fetched.prefix(pageLimit).reversed())

            case let .after(cursor), let .startingAt(cursor):
                let inclusive = if case .startingAt = direction { true } else { false }
                let fetched = try TextContentAccess.transcript(
                    meetingId: meetingId, position: .init(id: cursor.id, startTime: cursor.startTime),
                    inclusive: inclusive, confirmedOnly: true, limit: fetchLimit, in: db
                )
                hasEarlier = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(SELECT 1 FROM transcript_segments
                    WHERE meetingId = ?
                      AND (startedAt < ? OR (startedAt = ? AND id \(inclusive ? "<" : "<=") ?)))
                    """,
                    arguments: [meetingId, cursor.startTime, cursor.startTime, cursor.id]
                ) ?? false
                hasLater = fetched.count > pageLimit
                records = Array(fetched.prefix(pageLimit))
            }

            return TranscriptPage(
                segments: records.map(TranscriptSegment.init(from:)),
                hasEarlier: hasEarlier,
                hasLater: hasLater
            )
        }
    }

    nonisolated func hasTranscriptSegments(forMeetingId meetingId: UUID) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM transcript_segments
                    WHERE meetingId = ?
                )
                """,
                arguments: [meetingId]
            ) ?? false
        }
    }

    // MARK: - Notes

    /// ノートを保存する（insert or update）。
    nonisolated func upsertNote(_ note: MeetingNoteRecord) throws {
        try dbQueue.write { db in
            try note.save(db)
        }
    }

    // MARK: - Screenshots

    nonisolated func fetchScreenshots(forMeetingId meetingId: UUID) throws -> [MeetingScreenshotRecord] {
        try dbQueue.read { db in
            try MeetingScreenshotRecord
                .select(sql: MeetingScreenshotRecord.metadataSelection)
                .filter(Column("meetingId") == meetingId)
                .order(Column("capturedAt").asc)
                .fetchAll(db)
        }
    }

    func deleteScreenshots(ids: Set<UUID>, meetingId: UUID) async throws -> [MeetingScreenshotRecord] {
        guard !ids.isEmpty else { return [] }
        return try await dbQueue.write { db in
            let referencedScreenshotIds = try SummaryContent.fetchOne(db, key: meetingId)?
                .loadDocument()
                .referencedScreenshotIds ?? []
            let deletableIds = ids.subtracting(referencedScreenshotIds)
            guard !deletableIds.isEmpty else { return [] }

            let deletedScreenshots = try MeetingScreenshotRecord
                .filter(deletableIds.contains(Column("id")))
                .filter(Column("meetingId") == meetingId)
                .fetchAll(db)
            guard !deletedScreenshots.isEmpty else { return [] }
            let deletedIds = Set(deletedScreenshots.map(\.id))

            _ = try MeetingAttachmentRecord
                .filter(deletedIds.contains(Column("id")))
                .deleteAll(db)
            guard let workspaceId = try UUID.fetchOne(
                db,
                sql: "SELECT workspace_id FROM meetings WHERE id = ?",
                arguments: [meetingId]
            ) else { return deletedScreenshots }
            try SyncTransactionRecorder.recordBatches(
                workspaceId: workspaceId,
                operations: deletedScreenshots.map {
                    SyncOperationDraft(entity: .meetingAttachment, action: .delete, entityId: $0.id)
                },
                in: db
            )
            return deletedScreenshots
        }
    }

    // MARK: - Summaries

    func fetchSummary(forMeetingId meetingId: UUID) throws -> SummaryContent? {
        try dbQueue.read { db in
            try SummaryContent.fetchOne(db, key: meetingId)
        }
    }

    func updateSummaryGoogleFileId(
        forMeetingId meetingId: UUID,
        googleFileId: String?,
        expectedDocument: String
    ) throws -> Bool {
        try dbQueue.write { db in
            guard let summary = try SummaryContent.fetchOne(db, key: meetingId),
                  try summary.loadDocument().databaseJSONString() == expectedDocument else { return false }
            let googleDocsURL = googleFileId?.nilIfBlank.flatMap { fileId in
                SummaryExportRecord.googleDocsURL(fileId: fileId)
            }
            try SummaryExportRecord.setURL(
                googleDocsURL,
                meetingId: meetingId,
                type: .googleDocs,
                in: db
            )
            return true
        }
    }

    nonisolated func updateSummaryWorkspaceRelativePath(forMeetingId meetingId: UUID, relativePath: String?) throws {
        try dbQueue.write { db in
            guard try SummaryRecord.filter(Column("meetingId") == meetingId).fetchCount(db) > 0 else { return }
            try SummaryExportRecord.setURL(
                relativePath?.nilIfBlank.flatMap(SummaryExportRecord.workspaceURL(relativePath:)),
                meetingId: meetingId,
                type: .workspace,
                in: db
            )
        }
    }

    func fetchSummaryWorkspaceRelativePath(forMeetingId meetingId: UUID) throws -> String? {
        try dbQueue.read { db in
            try SummaryExportRecord.fetchOne(meetingId: meetingId, type: .workspace, in: db)?.workspaceRelativePath
        }
    }

    func fetchSummaryExport(
        forMeetingId meetingId: UUID,
        type: SummaryExportType
    ) throws -> SummaryExportRecord? {
        try dbQueue.read { db in
            try SummaryExportRecord.fetchOne(meetingId: meetingId, type: type, in: db)
        }
    }

    func fetchCalendarEvent(forMeetingId meetingId: UUID) throws -> CalendarEventRecord? {
        try dbQueue.read { db in
            let meeting = try MeetingRecord.fetchOne(db, key: meetingId)
            return try Self.fetchCalendarEvent(for: meeting, in: db)
        }
    }

    func fetchCodexChatContext(
        id meetingId: UUID
    ) async throws -> (meeting: MeetingRecord?, calendarEvent: CalendarEventRecord?) {
        try await dbQueue.read { db in
            let meeting = try MeetingRecord.fetchOne(db, key: meetingId)
            let calendarEvent = try Self.fetchCalendarEvent(for: meeting, in: db)
            return (meeting, calendarEvent)
        }
    }

    /// サマリーを保存する（insert or update）。
    nonisolated func upsertSummary(_ summary: SummaryContent) throws {
        try dbQueue.write { db in
            try TextContentAccess.requireComplete(entity: .summary, id: summary.meetingId, in: db)
            try summary.save(db)
            guard let workspaceId = try UUID.fetchOne(
                db,
                sql: "SELECT workspace_id FROM meetings WHERE id = ?",
                arguments: [summary.meetingId]
            ) else { return }
            try SyncTransactionRecorder.record(
                workspaceId: workspaceId,
                operations: [SyncInitialSnapshotBuilder.summaryOperation(summary, action: .upsert)],
                in: db
            )
        }
    }

    // MARK: - Composite

    /// ミーティング詳細をまとめて取得する（単一トランザクション）。
    struct MeetingDetail {
        let meeting: MeetingRecord?
        let calendarEvent: CalendarEventRecord?
        let recordingSessions: [RecordingSessionRecord]
        let screenshots: [MeetingScreenshotRecord]
        let note: MeetingNoteRecord?
        let summary: SummaryContent?
        let summaryContent: TextContentAvailability
        let transcriptContent: TextContentAvailability
        let summaryExports: [SummaryExportRecord]
    }

    nonisolated func fetchMeetingDetail(id meetingId: UUID) throws -> MeetingDetail {
        try dbQueue.read { db in
            let meeting = try MeetingRecord.fetchOne(db, key: meetingId)
            let calendarEvent = try Self.fetchCalendarEvent(for: meeting, in: db)
            let recordingSessions = try RecordingSessionRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("offsetSeconds").asc, Column("startedAt").asc)
                .fetchAll(db)
            let screenshots = try MeetingScreenshotRecord
                .select(sql: MeetingScreenshotRecord.metadataSelection)
                .filter(Column("meetingId") == meetingId)
                .order(Column("capturedAt").asc)
                .fetchAll(db)
            let note = try MeetingNoteRecord.fetchOne(db, key: meetingId)
            let summaryContent = try TextContentAccess.availability(entity: .summary, id: meetingId, in: db)
            let transcriptContent = try TextContentAccess.availability(entity: .transcript, id: meetingId, in: db)
            let summary = try TextContentAccess.cachedSummary(meetingId: meetingId, in: db)
            let summaryExports = try SummaryExportRecord
                .filter(Column("meetingId") == meetingId)
                .fetchAll(db)
            return MeetingDetail(
                meeting: meeting,
                calendarEvent: calendarEvent,
                recordingSessions: recordingSessions,
                screenshots: screenshots,
                note: note,
                summary: summary,
                summaryContent: summaryContent,
                transcriptContent: transcriptContent,
                summaryExports: summaryExports
            )
        }
    }

    private nonisolated static func fetchCalendarEvent(
        for meeting: MeetingRecord?,
        in db: Database
    ) throws -> CalendarEventRecord? {
        guard let icalUid = meeting?.calendarEventIcalUid,
              let recurrenceId = meeting?.calendarEventRecurrenceId
        else { return nil }
        return try CalendarEventRecord.fetch(
            key: CalendarEventKey(icalUid: icalUid, recurrenceId: recurrenceId),
            in: db
        )
    }
}

enum WorkspaceDeletionError: Error {
    case serverCopyExists
}

extension MeetingRepository {
    /// 現在の Workspace にある同一予定の最新 Meeting を返し、観測した予定情報も更新する。
    func resolveMeetingIdForCalendarEvent(
        _ event: CalendarEvent,
        workspaceId: UUID,
        observedAt: Date = .now
    ) throws -> UUID? {
        guard let key = event.key else { return nil }
        return try dbQueue.write { db in
            let meetingId = try MeetingRecord
                .select(Column("id"))
                .filter(Column("workspace_id") == workspaceId)
                .filter(Column("calendar_event_ical_uid") == key.icalUid)
                .filter(Column("calendar_event_recurrence_id") == key.recurrenceId)
                .order(Column("createdAt").desc, Column("id").desc)
                .asRequest(of: UUID.self)
                .fetchOne(db)
            if meetingId != nil {
                try CalendarEventRecord.upsert(event: event, now: observedAt, in: db)
            }
            return meetingId
        }
    }
}

extension MeetingRepository {
    nonisolated func prepareSegmentedAudioForDeletion(
        meetingIds: Set<UUID>,
        managedRootURL: URL
    ) async throws {
        let sessionIds = try recordingSessionIds(meetingIds: meetingIds)
        guard !sessionIds.isEmpty else { return }
        let store = try RecordingAudioStore(dbQueue: dbQueue, managedRootURL: managedRootURL)
        try await store.prepareForParentDeletion(sessionIds: sessionIds)
    }

    nonisolated func ensureNoLiveSegmentedAudio(meetingIds: Set<UUID>) throws {
        guard !meetingIds.isEmpty else { return }
        let sessionIds = try recordingSessionIds(meetingIds: meetingIds)
        guard !sessionIds.isEmpty else { return }
        let count = try dbQueue.read { db in
            try RecordingAudioSegmentRecord
                .filter(sessionIds.contains(Column("recordingSessionId")))
                .filter(Column("state") != RecordingAudioSegmentState.purged.rawValue)
                .fetchCount(db)
        }
        guard count == 0 else { throw RecordingAudioStoreError.invalidState }
    }

    nonisolated func recordingSessionIds(meetingIds: Set<UUID>) throws -> [UUID] {
        guard !meetingIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT id FROM recording_sessions WHERE meetingId IN (\(meetingIds.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(meetingIds)
            )
        }
    }

    private nonisolated func meetingIds(workspaceId: UUID) throws -> [UUID] {
        try dbQueue.read { db in
            try UUID.fetchAll(db, sql: "SELECT id FROM meetings WHERE workspace_id = ?", arguments: [workspaceId])
        }
    }
}
