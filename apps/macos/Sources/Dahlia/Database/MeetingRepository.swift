import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

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

    nonisolated let dbQueue: any DatabaseWriter

    nonisolated init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    // MARK: - Workspaces

    nonisolated func fetchLatestLocalAccountWorkspace() async throws -> WorkspaceRecord? {
        try await dbQueue.read { db in
            try WorkspaceRecord
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

    /// ワークスペースの表示名を更新する。
    nonisolated func updateWorkspaceName(id: UUID, name: String, appearance: ProjectAppearance? = nil) async throws -> WorkspaceRecord? {
        try await dbQueue.write { db in
            guard var workspace = try WorkspaceRecord.fetchOne(db, key: id) else { return nil }
            workspace.name = name
            if let appearance { workspace.appearance = appearance }
            try workspace.update(db)
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

    /// The app's account's oldest workspace, or `created` inserted when it has none.
    nonisolated func accountWorkspace(creating created: WorkspaceRecord) async throws -> WorkspaceRecord {
        try await dbQueue.write { db in
            if let existing = try WorkspaceRecord
                .order(Column("createdAt"), Column("id"))
                .fetchOne(db) {
                return existing
            }
            try created.insert(db)
            return created
        }
    }

    nonisolated func updateWorkspaceOutputLanguage(id: UUID, language: SummaryLanguage) async throws -> WorkspaceRecord? {
        try await dbQueue.write { db in
            guard var workspace = try WorkspaceRecord.fetchOne(db, key: id) else { return nil }
            guard workspace.generationSettings.outputLanguage != language else { return workspace }
            workspace.generationSettings.outputLanguage = language
            try workspace.update(db)
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

    /// ワークスペースを削除する（関連プロジェクト・ミーティングもカスケード削除）。
    nonisolated func deleteWorkspace(id: UUID) throws {
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
        let ids = try meetingIds(workspaceId: id)
        try await prepareSegmentedAudioForDeletion(
            meetingIds: Set(ids),
            managedRootURL: managedRootURL
        )
        try deleteWorkspace(id: id)
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
            }
        }
    }

    func deleteMeeting(id: UUID) throws {
        try ensureNoLiveSegmentedAudio(meetingIds: [id])
        let audioTargets = try BatchAudioCleanupService.deletionTargets(meetingIds: [id], dbQueue: dbQueue)
        try BatchAudioCleanupService.deleteFiles(audioTargets)
        try dbQueue.write { db in
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
            _ = try SummaryExportRecord
                .filter(Column("meetingId") == meetingId)
                .deleteAll(db)

            try Self.mergeGeneratedSummaryTags(tags, meetingId: meetingId, in: db)
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
        _ tags: [String], meetingId: UUID, in db: Database
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
        }
    }

    /// 孤立したタグマスタも自動削除する。
    func removeTag(name: String, fromMeetingId meetingId: UUID) throws {
        try dbQueue.write { db in
            guard let tag = try TagRecord.filter(Column("name") == name).fetchOne(db),
                  let tagId = tag.id else { return }
            _ = try MeetingTagRecord
                .filter(Column("meetingId") == meetingId && Column("tagId") == tagId)
                .deleteAll(db)
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

            case .earliest:
                let fetched = try TextContentAccess.transcript(
                    meetingId: meetingId, confirmedOnly: true, limit: fetchLimit, in: db
                )
                hasEarlier = false
                hasLater = fetched.count > pageLimit
                records = Array(fetched.prefix(pageLimit))

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

    /// Summary input excludes screenshots that image analysis found to have no shared material.
    nonisolated func fetchSummaryScreenshots(forMeetingId meetingId: UUID) throws -> [MeetingScreenshotRecord] {
        try dbQueue.read { db in
            try MeetingScreenshotRecord
                .select(sql: MeetingScreenshotRecord.metadataSelection)
                .filter(Column("meetingId") == meetingId)
                .filter(sql: """
                NOT EXISTS (SELECT 1 FROM files WHERE files.id = meeting_images.fileId
                    AND json_extract(files.metadata, '$.informativeReason') IS NOT NULL)
                """)
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
            return deletedScreenshots
        }
    }

    // MARK: - Summaries

    func fetchSummary(forMeetingId meetingId: UUID) throws -> SummaryContent? {
        try dbQueue.read { db in
            try SummaryContent.fetchOne(db, key: meetingId)
        }
    }

    nonisolated func updateSummaryWorkspaceRelativePath(
        forMeetingId meetingId: UUID, relativePath: String?, expectedWorkspaceID: UUID? = nil
    ) throws {
        try dbQueue.write { db in
            if let expectedWorkspaceID {
                guard try MeetingRecord.fetchOne(db, key: meetingId)?.workspaceId == expectedWorkspaceID else {
                    throw ProjectWorkspaceError.invalidMoveDestination
                }
            }
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
        }
    }

    /// Makes a retained version the current summary by moving the current marker; no version is added.
    /// A Workspace with a folder keeps one exported file per meeting and only overwrites it, so it has no promotion.
    nonisolated func promoteSummary(meetingID: UUID, version: Int) throws {
        try dbQueue.write { db in
            guard let meeting = try MeetingRecord.fetchOne(db, key: meetingID),
                  let workspace = try WorkspaceRecord.fetchOne(db, key: meeting.workspaceId),
                  workspace.url == nil,
                  var summary = try TextContentAccess.summary(meetingId: meetingID, in: db),
                  let promoted = try SummaryVersionRecord.fetchOne(
                      db, key: ["meetingId": meetingID.databaseValue, "version": version.databaseValue]
                  )
            else { throw TextContentError.changed }
            guard !promoted.isCurrent else { return }
            // The marker moves first so the body triggers see the promoted version as current and add nothing.
            try db.execute(sql: "UPDATE summary_versions SET isCurrent = 0 WHERE meetingId = ? AND isCurrent", arguments: [meetingID])
            try db.execute(
                sql: "UPDATE summary_versions SET isCurrent = 1 WHERE meetingId = ? AND version = ?", arguments: [meetingID, version]
            )
            summary.title = promoted.title
            summary.document = promoted.document
            try summary.save(db)
            _ = try SummaryExportRecord.filter(Column("meetingId") == meetingID).deleteAll(db)
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
