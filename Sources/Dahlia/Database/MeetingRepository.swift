import Foundation
import GRDB

/// ミーティング・セグメント・プロジェクト・保管庫の DB クエリを集約するリポジトリ。
@MainActor
final class MeetingRepository {
    struct AppendRecordingContext {
        let meetingCreatedAt: Date?
        let firstSegmentStartTime: Date?
        let lastSegmentEndTime: Date?
        let segmentIds: Set<UUID>
        let recordingSessions: [RecordingSessionRecord]

        var nextOffsetSeconds: TimeInterval {
            let sessionDuration = recordingSessions.reduce(0) { total, session in
                let duration = session.duration
                    ?? session.endedAt.map { max(0, $0.timeIntervalSince(session.startedAt)) }
                    ?? 0
                return total + duration
            }

            if sessionDuration > 0 {
                return sessionDuration
            }

            guard let firstSegmentStartTime,
                  let lastSegmentEndTime else { return 0 }
            return max(0, lastSegmentEndTime.timeIntervalSince(firstSegmentStartTime))
        }
    }

    private static let generatedSummaryTagColorHex = "#808080"

    private let dbQueue: DatabaseQueue

    nonisolated init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Vaults

    /// 全保管庫を最終オープン日時の降順で取得する。
    func fetchAllVaults() throws -> [VaultRecord] {
        try dbQueue.read { db in
            try VaultRecord.order(Column("lastOpenedAt").desc).fetchAll(db)
        }
    }

    /// 最後にオープンした保管庫を取得する。
    func fetchLastOpenedVault() throws -> VaultRecord? {
        try dbQueue.read { db in
            try VaultRecord.order(Column("lastOpenedAt").desc).fetchOne(db)
        }
    }

    /// 保管庫を登録する。
    func insertVault(_ vault: VaultRecord) throws {
        try dbQueue.write { db in
            try vault.insert(db)
        }
    }

    /// 保管庫を登録解除する（関連プロジェクト・ミーティングもカスケード削除）。
    func deleteVault(id: UUID) throws {
        let meetingIds = try meetingIds(vaultId: id)
        try ensureNoLiveSegmentedAudio(meetingIds: Set(meetingIds))
        let audioTargets = try BatchAudioCleanupService.deletionTargets(vaultId: id, dbQueue: dbQueue)
        try BatchAudioCleanupService.deleteFiles(audioTargets)
        try dbQueue.write { db in
            _ = try VaultRecord.deleteOne(db, key: id)
        }
    }

    func deleteVaultSafely(
        id: UUID,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) async throws {
        let ids = try meetingIds(vaultId: id)
        try await prepareSegmentedAudioForDeletion(
            meetingIds: Set(ids),
            managedRootURL: managedRootURL
        )
        try deleteVault(id: id)
    }

    /// 保管庫の最終オープン日時を更新する。
    func updateVaultLastOpened(id: UUID) throws {
        try dbQueue.write { db in
            if var record = try VaultRecord.fetchOne(db, key: id) {
                record.lastOpenedAt = Date()
                try record.update(db)
            }
        }
    }

    // MARK: - Instructions

    func fetchInstructions(vaultId: UUID) throws -> [InstructionRecord] {
        try dbQueue.read { db in
            try InstructionRecord
                .filter(Column("vaultId") == vaultId)
                .order(Column("name").asc)
                .fetchAll(db)
        }
    }

    func fetchInstruction(id: UUID) throws -> InstructionRecord? {
        try dbQueue.read { db in
            try InstructionRecord.fetchOne(db, key: id)
        }
    }

    func createInstruction(vaultId: UUID, name: String, content: String) throws -> InstructionRecord {
        try dbQueue.write { db in
            let now = Date()
            let record = InstructionRecord(
                id: .v7(),
                vaultId: vaultId,
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

    func fetchMeetings(forProjectId projectId: UUID) throws -> [MeetingRecord] {
        try dbQueue.read { db in
            try MeetingRecord
                .filter(Column("projectId") == projectId)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    func fetchMeeting(id: UUID) throws -> MeetingRecord? {
        try dbQueue.read { db in
            try MeetingRecord.fetchOne(db, key: id)
        }
    }

    func fetchAppendRecordingContext(forMeetingId meetingId: UUID) throws -> AppendRecordingContext {
        try dbQueue.read { db in
            let meeting = try MeetingRecord.fetchOne(db, key: meetingId)
            let segments = try TranscriptSegmentRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("startTime").asc)
                .fetchAll(db)
            let sessions = try RecordingSessionRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("offsetSeconds").asc, Column("startedAt").asc)
                .fetchAll(db)
            return AppendRecordingContext(
                meetingCreatedAt: meeting?.createdAt,
                firstSegmentStartTime: segments.first?.startTime,
                lastSegmentEndTime: segments.last.map { $0.endTime ?? $0.startTime },
                segmentIds: Set(segments.map(\.id)),
                recordingSessions: sessions
            )
        }
    }

    func updateMeetingCreatedAt(id: UUID, createdAt: Date) throws {
        try dbQueue.write { db in
            if var record = try MeetingRecord.fetchOne(db, key: id) {
                record.createdAt = createdAt
                record.updatedAt = createdAt
                try record.update(db)
            }
        }
    }

    func renameMeeting(id: UUID, newName: String) throws {
        try dbQueue.write { db in
            if var record = try MeetingRecord.fetchOne(db, key: id) {
                record.name = newName
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

    func moveMeeting(id: UUID, toProjectId: UUID?) throws {
        try dbQueue.write { db in
            if var record = try MeetingRecord.fetchOne(db, key: id) {
                record.projectId = toProjectId
                try record.update(db)
            }
        }
    }

    /// 複数のミーティングを一括移動する。
    func moveMeetings(ids: Set<UUID>, toProjectId: UUID?) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            _ = try MeetingRecord
                .filter(ids.contains(Column("id")))
                .updateAll(db, Column("projectId").set(to: toProjectId))
        }
    }

    func applyGeneratedSummary(
        toMeetingId meetingId: UUID,
        document: SummaryDocument,
        renderedBody: String,
        tags: [String]
    ) throws {
        try dbQueue.write { db in
            guard var meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { return }

            let existingSummary = try SummaryRecord.fetchOne(db, key: meetingId)
            let normalizedTitle = Self.normalizedGeneratedMetadata(document.title, maximumLength: 120)
            if let normalizedTitle {
                meeting.name = normalizedTitle
            }
            if let description = Self.normalizedGeneratedMetadata(document.description, maximumLength: 240) {
                meeting.description = description
            }
            meeting.updatedAt = Date()
            try meeting.update(db)

            let record = try SummaryRecord(
                meetingId: meetingId,
                title: normalizedTitle ?? existingSummary?.title ?? "",
                summary: renderedBody,
                document: document.databaseJSONString(),
                vaultRelativePath: nil,
                googleFileId: nil,
                createdAt: existingSummary?.createdAt ?? Date()
            )
            try record.save(db)
            _ = try SummaryExportRecord
                .filter(Column("meetingId") == meetingId)
                .deleteAll(db)

            let tagNames = tags.filter { !$0.isEmpty }
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
    }

    private static func normalizedGeneratedMetadata(_ value: String, maximumLength: Int) -> String? {
        let oneLine = value
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .nilIfBlank
        return oneLine.map { String($0.prefix(maximumLength)) }
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

    func fetchAllTags() throws -> [TagRecord] {
        try dbQueue.read { db in
            try TagRecord.order(Column("name").asc).fetchAll(db)
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

    func updateTagColor(id: Int64, colorHex: String) throws {
        try dbQueue.write { db in
            if var tag = try TagRecord.fetchOne(db, key: id) {
                tag.colorHex = colorHex
                try tag.update(db)
            }
        }
    }

    // MARK: - Segments

    func fetchSegments(forMeetingId meetingId: UUID) throws -> [TranscriptSegmentRecord] {
        try dbQueue.read { db in
            try TranscriptSegmentRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("startTime").asc)
                .fetchAll(db)
        }
    }

    func fetchSegmentIds(forMeetingId meetingId: UUID) throws -> Set<UUID> {
        try dbQueue.read { db in
            let ids = try TranscriptSegmentRecord
                .select(Column("id"))
                .filter(Column("meetingId") == meetingId)
                .asRequest(of: UUID.self)
                .fetchAll(db)
            return Set(ids)
        }
    }

    // MARK: - Notes

    /// 指定ミーティングに紐づくノートを取得する（1 meeting = 1 note）。
    func fetchNote(forMeetingId meetingId: UUID) throws -> MeetingNoteRecord? {
        try dbQueue.read { db in
            try MeetingNoteRecord.fetchOne(db, key: meetingId)
        }
    }

    /// ノートを保存する（insert or update）。
    nonisolated func upsertNote(_ note: MeetingNoteRecord) throws {
        try dbQueue.write { db in
            try note.save(db)
        }
    }

    /// ノートを削除する。
    func deleteNote(meetingId: UUID) throws {
        try dbQueue.write { db in
            _ = try MeetingNoteRecord.deleteOne(db, key: meetingId)
        }
    }

    // MARK: - Screenshots

    nonisolated func fetchScreenshots(forMeetingId meetingId: UUID) throws -> [MeetingScreenshotRecord] {
        try dbQueue.read { db in
            try MeetingScreenshotRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("capturedAt").asc)
                .fetchAll(db)
        }
    }

    func deleteScreenshot(id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try MeetingScreenshotRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - Summaries

    func fetchSummary(forMeetingId meetingId: UUID) throws -> SummaryRecord? {
        try dbQueue.read { db in
            try SummaryRecord.fetchOne(db, key: meetingId)
        }
    }

    func updateSummaryGoogleFileId(forMeetingId meetingId: UUID, googleFileId: String?) throws {
        try dbQueue.write { db in
            guard try SummaryRecord.fetchOne(db, key: meetingId) != nil else { return }
            let googleDocsURL = googleFileId?.nilIfBlank.flatMap { fileId in
                SummaryExportRecord.googleDocsURL(fileId: fileId)
            }
            try db.execute(
                sql: "UPDATE summaries SET googleFileId = ? WHERE meetingId = ?",
                arguments: [googleFileId?.nilIfBlank, meetingId]
            )
            try SummaryExportRecord.setURL(
                googleDocsURL,
                meetingId: meetingId,
                type: .googleDocs,
                in: db
            )
        }
    }

    nonisolated func updateSummaryVaultRelativePath(forMeetingId meetingId: UUID, relativePath: String?) throws {
        try dbQueue.write { db in
            guard try SummaryRecord.fetchOne(db, key: meetingId) != nil else { return }
            try db.execute(
                sql: "UPDATE summaries SET vaultRelativePath = ? WHERE meetingId = ?",
                arguments: [relativePath?.nilIfBlank, meetingId]
            )
            try SummaryExportRecord.setURL(
                relativePath?.nilIfBlank.flatMap(SummaryExportRecord.vaultURL(relativePath:)),
                meetingId: meetingId,
                type: .vault,
                in: db
            )
        }
    }

    func fetchSummaryVaultRelativePath(forMeetingId meetingId: UUID) throws -> String? {
        try dbQueue.read { db in
            try SummaryExportRecord.fetchOne(meetingId: meetingId, type: .vault, in: db)?.vaultRelativePath
                ?? SummaryRecord.fetchOne(db, key: meetingId)?.vaultRelativePath
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

    /// サマリーを保存する（insert or update）。
    nonisolated func upsertSummary(_ summary: SummaryRecord) throws {
        try dbQueue.write { db in
            let googleDocsURL = summary.googleFileId?.nilIfBlank.flatMap { fileId in
                SummaryExportRecord.googleDocsURL(fileId: fileId)
            }
            try summary.save(db)
            try SummaryExportRecord.setURL(
                summary.vaultRelativePath?.nilIfBlank.flatMap(SummaryExportRecord.vaultURL(relativePath:)),
                meetingId: summary.meetingId,
                type: .vault,
                in: db
            )
            try SummaryExportRecord.setURL(
                googleDocsURL,
                meetingId: summary.meetingId,
                type: .googleDocs,
                in: db
            )
        }
    }

    // MARK: - Composite

    /// ミーティング詳細をまとめて取得する（単一トランザクション）。
    struct MeetingDetail {
        let meeting: MeetingRecord?
        let calendarEvent: CalendarEventRecord?
        let segments: [TranscriptSegmentRecord]
        let recordingSessions: [RecordingSessionRecord]
        let screenshots: [MeetingScreenshotRecord]
        let note: MeetingNoteRecord?
        let summary: SummaryRecord?
        let summaryExports: [SummaryExportRecord]
    }

    nonisolated func fetchMeetingDetail(id meetingId: UUID) throws -> MeetingDetail {
        try dbQueue.read { db in
            let meeting = try MeetingRecord.fetchOne(db, key: meetingId)
            let calendarEvent = try Self.fetchCalendarEvent(for: meeting, in: db)
            let segments = try TranscriptSegmentRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("startTime").asc)
                .fetchAll(db)
            let recordingSessions = try RecordingSessionRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("offsetSeconds").asc, Column("startedAt").asc)
                .fetchAll(db)
            let screenshots = try MeetingScreenshotRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("capturedAt").asc)
                .fetchAll(db)
            let note = try MeetingNoteRecord.fetchOne(db, key: meetingId)
            let summary = try SummaryRecord.fetchOne(db, key: meetingId)
            let summaryExports = try SummaryExportRecord
                .filter(Column("meetingId") == meetingId)
                .fetchAll(db)
            return MeetingDetail(
                meeting: meeting,
                calendarEvent: calendarEvent,
                segments: segments,
                recordingSessions: recordingSessions,
                screenshots: screenshots,
                note: note,
                summary: summary,
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
    /// 現在の Vault にある同一予定の最新 Meeting を返し、観測した予定情報も更新する。
    func resolveMeetingIdForCalendarEvent(
        _ event: CalendarEvent,
        vaultId: UUID,
        observedAt: Date = .now
    ) throws -> UUID? {
        guard let key = event.key else { return nil }
        return try dbQueue.write { db in
            let meetingId = try MeetingRecord
                .select(Column("id"))
                .filter(Column("vaultId") == vaultId)
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

// MARK: - Projects

extension MeetingRepository {
    /// 指定保管庫のプロジェクトを name 順で取得する。
    func fetchAllProjects(vaultId: UUID) throws -> [ProjectRecord] {
        try dbQueue.read { db in
            try ProjectRecord
                .filter(Column("vaultId") == vaultId)
                .order(Column("name").asc)
                .fetchAll(db)
        }
    }

    func fetchProject(id: UUID) throws -> ProjectRecord? {
        try dbQueue.read { db in
            try ProjectRecord.fetchOne(db, key: id)
        }
    }

    /// 指定名のプロジェクトを取得し、存在しなければ作成して返す。
    func fetchOrCreateProject(name: String, vaultId: UUID) throws -> ProjectRecord {
        try dbQueue.write { db in
            if let existing = try ProjectRecord
                .filter(Column("vaultId") == vaultId)
                .filter(Column("name") == name)
                .fetchOne(db) {
                return existing
            }
            let record = ProjectRecord(id: .v7(), vaultId: vaultId, name: name, createdAt: .now)
            try record.insert(db)
            return record
        }
    }

    /// 複数の name を一括で INSERT OR IGNORE する。
    func upsertProjects(names: [String], vaultId: UUID) throws {
        guard !names.isEmpty else { return }
        try dbQueue.write { db in
            try ProjectRecord.upsertAll(names: names, vaultId: vaultId, in: db)
        }
    }

    /// name が指定プレフィクスで始まるレコードを一括リネームする。
    func renameProjectsByPrefix(oldPrefix: String, newPrefix: String, vaultId: UUID) throws {
        try dbQueue.write { db in
            try ProjectRecord.renameByPrefix(oldPrefix: oldPrefix, newPrefix: newPrefix, vaultId: vaultId, in: db)
            try SummaryRecord.renameVaultRelativePathsByPrefix(
                oldPrefix: oldPrefix,
                newPrefix: newPrefix,
                vaultId: vaultId,
                in: db
            )
            try SummaryExportRecord.renameVaultPathsByPrefix(
                oldPrefix: oldPrefix,
                newPrefix: newPrefix,
                vaultId: vaultId,
                in: db
            )
        }
    }

    func deleteProject(id: UUID) throws {
        try dbQueue.write { db in
            _ = try ProjectRecord.deleteOne(db, key: id)
        }
    }

    /// 指定プロジェクトとその配下を一括削除する。
    func deleteProjectsByPrefix(name: String, vaultId: UUID) throws {
        try dbQueue.write { db in
            _ = try ProjectRecord.deleteByPrefix(name, vaultId: vaultId, in: db)
        }
    }

    /// 指定プレフィクスに一致するプロジェクトの missingOnDisk フラグをクリアする。
    func clearProjectsMissing(prefix: String, vaultId: UUID) throws {
        try dbQueue.write { db in
            try ProjectRecord.setMissingByPrefix(prefix, missing: false, vaultId: vaultId, in: db)
        }
    }

    func updateProjectDescription(id: UUID, description: String) throws {
        try dbQueue.write { db in
            guard var record = try ProjectRecord.fetchOne(db, key: id) else {
                throw ProjectRecord.recordNotFound(db, key: id)
            }
            record.description = description
            try record.update(db)
        }
    }

    func deleteProjectHierarchy(
        name: String,
        vaultId: UUID,
        meetingDisposition: ProjectMeetingDisposition
    ) throws {
        let meetingIds = try dbQueue.read { db in
            let projectIds = try ProjectRecord.hierarchy(prefix: name, vaultId: vaultId, in: db).map(\.id)
            guard !projectIds.isEmpty else { return Set<UUID>() }
            return try UUID.fetchSet(
                db,
                sql: "SELECT id FROM meetings WHERE projectId IN (\(projectIds.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(projectIds)
            )
        }

        let audioTargets: [BatchAudioCleanupService.DeletionTarget]
        if meetingDisposition == .deleteMeetings {
            try ensureNoLiveSegmentedAudio(meetingIds: meetingIds)
            audioTargets = try BatchAudioCleanupService.deletionTargets(meetingIds: meetingIds, dbQueue: dbQueue)
        } else {
            audioTargets = []
        }
        try BatchAudioCleanupService.deleteFiles(audioTargets)

        try dbQueue.write { db in
            let projectIds = try Set(ProjectRecord.hierarchy(prefix: name, vaultId: vaultId, in: db).map(\.id))

            switch meetingDisposition {
            case let .move(destinationId):
                guard let destination = try ProjectRecord.fetchOne(db, key: destinationId),
                      destination.vaultId == vaultId,
                      !destination.missingOnDisk,
                      !projectIds.contains(destinationId)
                else {
                    throw ProjectWorkspaceError.invalidMoveDestination
                }
                if !meetingIds.isEmpty {
                    _ = try MeetingRecord
                        .filter(meetingIds.contains(Column("id")))
                        .updateAll(db, Column("projectId").set(to: destinationId))
                    try SummaryRecord.clearVaultRelativePaths(
                        meetingIds: meetingIds,
                        underProjectPrefix: name,
                        in: db
                    )
                    try SummaryExportRecord.clearVaultPaths(
                        meetingIds: meetingIds,
                        underProjectPrefix: name,
                        in: db
                    )
                }
            case .deleteMeetings:
                if !meetingIds.isEmpty {
                    _ = try MeetingRecord.filter(meetingIds.contains(Column("id"))).deleteAll(db)
                }
            }

            _ = try ProjectRecord.deleteByPrefix(name, vaultId: vaultId, in: db)
        }
    }

    func prepareSegmentedAudioForProjectDeletion(
        name: String,
        vaultId: UUID,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) async throws {
        let ids = try await dbQueue.read { db in
            let projectIds = try ProjectRecord.hierarchy(prefix: name, vaultId: vaultId, in: db).map(\.id)
            guard !projectIds.isEmpty else { return Set<UUID>() }
            return try UUID.fetchSet(
                db,
                sql: "SELECT id FROM meetings WHERE projectId IN (\(projectIds.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(projectIds)
            )
        }
        try await prepareSegmentedAudioForDeletion(meetingIds: ids, managedRootURL: managedRootURL)
    }

    private func prepareSegmentedAudioForDeletion(
        meetingIds: Set<UUID>,
        managedRootURL: URL
    ) async throws {
        let sessionIds = try recordingSessionIds(meetingIds: meetingIds)
        guard !sessionIds.isEmpty else { return }
        let store = try RecordingAudioStore(dbQueue: dbQueue, managedRootURL: managedRootURL)
        try await store.prepareForParentDeletion(sessionIds: sessionIds)
    }

    private func ensureNoLiveSegmentedAudio(meetingIds: Set<UUID>) throws {
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

    private func recordingSessionIds(meetingIds: Set<UUID>) throws -> [UUID] {
        guard !meetingIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT id FROM recording_sessions WHERE meetingId IN (\(meetingIds.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(meetingIds)
            )
        }
    }

    private func meetingIds(vaultId: UUID) throws -> [UUID] {
        try dbQueue.read { db in
            try UUID.fetchAll(db, sql: "SELECT id FROM meetings WHERE vaultId = ?", arguments: [vaultId])
        }
    }
}
