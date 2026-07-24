import DahliaRuntimeSupport
import Foundation
import GRDB

/// ミーティング・セグメント・プロジェクト・保管庫の DB クエリを集約するリポジトリ。
@MainActor
// Query methods share one MainActor-isolated database boundary.
// swiftlint:disable:next type_body_length
final class MeetingRepository {
    struct MeetingMoveCandidate {
        let meetingId: UUID
        let projectId: UUID?
        let hasVaultExport: Bool
        let vaultRelativePath: String?
    }

    struct MeetingVaultExportUpdate {
        let meetingId: UUID
        let relativePath: String?
    }

    private static func updateVaultExports(
        _ updates: [MeetingVaultExportUpdate],
        forMeetingIds meetingIds: Set<UUID>,
        in db: Database
    ) throws {
        let existingRecords = try SummaryExportRecord
            .filter(meetingIds.contains(Column("meetingId")))
            .filter(Column("type") == SummaryExportType.vault)
            .fetchAll(db)
        let existingByMeetingId = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.meetingId, $0) })
        let updatedAt = Date.now

        for update in updates where meetingIds.contains(update.meetingId) {
            guard let url = update.relativePath.flatMap(SummaryExportRecord.vaultURL(relativePath:)) else {
                if let existing = existingByMeetingId[update.meetingId] {
                    _ = try existing.delete(db)
                }
                continue
            }
            try SummaryExportRecord(
                meetingId: update.meetingId,
                type: .vault,
                url: url,
                createdAt: existingByMeetingId[update.meetingId]?.createdAt ?? updatedAt,
                updatedAt: updatedAt
            ).save(db)
        }
    }

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
        try dbQueue.writeWithoutTransaction { db in
            try db.inTransaction {
                try Self.deleteVaultRows(id: id, in: db)
                return .rollback
            }
        }
        try BatchAudioCleanupService.deleteFiles(audioTargets)
        try dbQueue.write { db in
            try Self.deleteVaultRows(id: id, in: db)
        }
    }

    private static func deleteVaultRows(id: UUID, in db: Database) throws {
        let projects = try ProjectRecord.fetchResolvedAll(vaultId: id, in: db)
            .sorted {
                $0.name.split(separator: "/").count > $1.name.split(separator: "/").count
            }
        for project in projects {
            _ = try ProjectRecord.deleteOne(db, key: project.id)
        }
        _ = try VaultRecord.deleteOne(db, key: id)
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

    /// 未確認または失敗したバッチ録音を、音声ファイルと部分結果を含めて明示的に破棄する。
    @discardableResult
    func discardUnprocessedBatchSessionSafely(
        id: UUID,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) async throws -> Bool {
        try await BatchTranscriptionDiscardService.discardUnprocessedSessionSafely(
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

    func fetchMeetingMoveCandidates(ids: Set<UUID>, vaultId: UUID) throws -> [MeetingMoveCandidate] {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { db in
            let meetings = try MeetingRecord
                .filter(ids.contains(Column("id")))
                .filter(Column("vaultId") == vaultId)
                .fetchAll(db)
            let vaultExports = try SummaryExportRecord
                .filter(ids.contains(Column("meetingId")))
                .filter(Column("type") == SummaryExportType.vault)
                .fetchAll(db)
            let vaultExportsByMeetingId = Dictionary(uniqueKeysWithValues: vaultExports.map { ($0.meetingId, $0) })

            return meetings.map { meeting in
                let vaultExport = vaultExportsByMeetingId[meeting.id]
                return MeetingMoveCandidate(
                    meetingId: meeting.id,
                    projectId: meeting.projectId,
                    hasVaultExport: vaultExport != nil,
                    vaultRelativePath: vaultExport?.vaultRelativePath
                )
            }
        }
    }

    func externalVaultSummaryPaths(
        movingMeetingIds: Set<UUID>,
        vaultId: UUID
    ) throws -> [String] {
        guard !movingMeetingIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            let placeholders = movingMeetingIds.map { _ in "?" }.joined(separator: ",")
            var arguments: StatementArguments = [SummaryExportType.vault, vaultId]
            arguments += StatementArguments(movingMeetingIds)
            let records = try SummaryExportRecord.fetchAll(
                db,
                sql: """
                SELECT summary_exports.*
                FROM summary_exports
                JOIN meetings ON meetings.id = summary_exports.meetingId
                WHERE summary_exports.type = ?
                  AND meetings.vaultId = ?
                  AND summary_exports.meetingId NOT IN (\(placeholders))
                """,
                arguments: arguments
            )
            return records.compactMap(\.vaultRelativePath)
        }
    }

    func commitMeetingMove(
        ids: Set<UUID>,
        toProjectId: UUID?,
        vaultId: UUID,
        vaultExportUpdates: [MeetingVaultExportUpdate]
    ) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            if let toProjectId {
                guard let destination = try ProjectRecord.fetchOne(db, key: toProjectId),
                      destination.vaultId == vaultId,
                      !destination.missingOnDisk
                else {
                    throw ProjectWorkspaceError.invalidMoveDestination
                }
            }

            _ = try MeetingRecord
                .filter(ids.contains(Column("id")))
                .filter(Column("vaultId") == vaultId)
                .updateAll(db, Column("projectId").set(to: toProjectId))

            try Self.updateVaultExports(vaultExportUpdates, forMeetingIds: ids, in: db)
        }
    }

    func applyGeneratedSummary(
        toMeetingId meetingId: UUID,
        document: SummaryDocument,
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
                document: document.databaseJSONString(),
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

    nonisolated func fetchSegments(forMeetingId meetingId: UUID) throws -> [TranscriptSegmentRecord] {
        try dbQueue.read { db in
            try TranscriptSegmentRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("startTime").asc, Column("id").asc)
                .fetchAll(db)
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
            let records: [TranscriptSegmentRecord]
            let hasEarlier: Bool
            let hasLater: Bool

            switch direction {
            case .latest:
                let fetched = try TranscriptSegmentRecord.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM transcript_segments
                    WHERE meetingId = ? AND isConfirmed = 1
                    ORDER BY startTime DESC, id DESC
                    LIMIT ?
                    """,
                    arguments: [meetingId, fetchLimit]
                )
                hasEarlier = fetched.count > pageLimit
                hasLater = false
                records = Array(fetched.prefix(pageLimit).reversed())

            case let .before(cursor):
                let fetched = try TranscriptSegmentRecord.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM transcript_segments
                    WHERE meetingId = ? AND isConfirmed = 1
                      AND (startTime < ? OR (startTime = ? AND id < ?))
                    ORDER BY startTime DESC, id DESC
                    LIMIT ?
                    """,
                    arguments: [meetingId, cursor.startTime, cursor.startTime, cursor.id, fetchLimit]
                )
                hasEarlier = fetched.count > pageLimit
                hasLater = true
                records = Array(fetched.prefix(pageLimit).reversed())

            case let .after(cursor):
                let fetched = try TranscriptSegmentRecord.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM transcript_segments
                    WHERE meetingId = ? AND isConfirmed = 1
                      AND (startTime > ? OR (startTime = ? AND id > ?))
                    ORDER BY startTime ASC, id ASC
                    LIMIT ?
                    """,
                    arguments: [meetingId, cursor.startTime, cursor.startTime, cursor.id, fetchLimit]
                )
                hasEarlier = true
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
                    WHERE meetingId = ? AND isConfirmed = 1
                )
                """,
                arguments: [meetingId]
            ) ?? false
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

    func deleteScreenshots(ids: Set<UUID>, meetingId: UUID) async throws -> [MeetingScreenshotRecord] {
        guard !ids.isEmpty else { return [] }
        return try await dbQueue.write { db in
            let referencedScreenshotIds = try SummaryRecord.fetchOne(db, key: meetingId)?
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

            _ = try MeetingScreenshotRecord
                .filter(deletedIds.contains(Column("id")))
                .deleteAll(db)
            return deletedScreenshots
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
    nonisolated func upsertSummary(_ summary: SummaryRecord) throws {
        try dbQueue.write { db in
            try summary.save(db)
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
        let summary: SummaryRecord?
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
    func fetchPreviousMeetingMetadata(
        forMeetingId meetingId: UUID,
        limit: Int
    ) throws -> [SummaryPreviousMeetingMetadata] {
        guard limit > 0 else { return [] }

        return try dbQueue.read { db in
            guard let currentMeeting = try MeetingRecord.fetchOne(db, key: meetingId),
                  let icalUid = currentMeeting.calendarEventIcalUid?.nilIfBlank else {
                return []
            }
            let currentCalendarEvent = try Self.fetchCalendarEvent(for: currentMeeting, in: db)
            let cutoff = currentCalendarEvent?.start ?? currentMeeting.createdAt
            let rows = try Row.fetchCursor(
                db,
                sql: """
                SELECT meetings.id AS meetingId,
                       meetings.name AS name,
                       meetings.createdAt AS recordedAt,
                       calendar_events.start AS calendarStart,
                       calendar_events.end AS calendarEnd,
                       summaries.document AS summaryDocument
                FROM meetings
                JOIN summaries ON summaries.meetingId = meetings.id
                LEFT JOIN calendar_events
                  ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
                 AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
                WHERE meetings.vaultId = ?
                  AND meetings.calendar_event_ical_uid = ?
                  AND meetings.id <> ?
                  AND COALESCE(calendar_events.start, meetings.createdAt) < ?
                ORDER BY COALESCE(calendar_events.start, meetings.createdAt) DESC,
                         meetings.createdAt DESC,
                         meetings.id DESC
                """,
                arguments: [currentMeeting.vaultId, icalUid, meetingId, cutoff]
            )

            var summaries: [SummaryPreviousMeetingMetadata] = []
            while summaries.count < limit, let row = try rows.next() {
                let documentJSON: String = row["summaryDocument"]
                guard (try? JSONDecoder().decode(
                    SummaryDocument.self,
                    from: Data(documentJSON.utf8)
                )) != nil else { continue }
                summaries.append(SummaryPreviousMeetingMetadata(
                    meetingId: row["meetingId"],
                    name: row["name"],
                    recordedAt: row["recordedAt"],
                    calendarStart: row["calendarStart"],
                    calendarEnd: row["calendarEnd"]
                ))
            }
            return summaries
        }
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
            try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
        }
    }

    func meetingIds(projectHierarchy name: String, vaultId: UUID) throws -> Set<UUID> {
        try dbQueue.read { db in
            let projectIds = try ProjectRecord.hierarchy(path: name, vaultId: vaultId, in: db).map(\.id)
            guard !projectIds.isEmpty else { return [] }
            return try UUID.fetchSet(
                db,
                sql: "SELECT id FROM meetings WHERE projectId IN (\(projectIds.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(projectIds)
            )
        }
    }

    func fetchProject(id: UUID) throws -> ProjectRecord? {
        try dbQueue.read { db in
            try ProjectRecord.fetchResolved(id: id, in: db)
        }
    }

    func createProject(
        vaultId: UUID,
        parentProjectId: UUID?,
        leafName: String,
        description: String,
        projectType: ProjectType?
    ) throws -> ProjectRecord {
        try dbQueue.write { db in
            guard DahliaProjectName.normalizedLeafName(leafName) == leafName else {
                throw ProjectWorkspaceError.invalidName
            }
            if let parentProjectId {
                guard let parent = try ProjectRecord.fetchOne(db, key: parentProjectId),
                      parent.vaultId == vaultId else {
                    throw ProjectWorkspaceError.projectNotFound
                }
            }
            let record = ProjectRecord(
                id: .v7(),
                vaultId: vaultId,
                parentProjectId: parentProjectId,
                leafName: leafName,
                createdAt: .now,
                description: description,
                projectType: parentProjectId == nil ? (projectType ?? .undefined) : nil
            )
            try record.insert(db)
            return try ProjectRecord.fetchResolved(id: record.id, in: db) ?? record
        }
    }

    /// 指定名のプロジェクトを取得し、存在しなければ作成して返す。
    func fetchOrCreateProject(name: String, vaultId: UUID) throws -> ProjectRecord {
        try dbQueue.write { db in
            try ProjectRecord.upsertAll(paths: [name], vaultId: vaultId, in: db)
            guard let project = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
                .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw ProjectWorkspaceError.projectNotFound
            }
            return project
        }
    }

    /// 複数の name を一括で INSERT OR IGNORE する。
    func upsertProjects(names: [String], vaultId: UUID) throws {
        guard !names.isEmpty else { return }
        try dbQueue.write { db in
            try ProjectRecord.upsertAll(paths: names, vaultId: vaultId, in: db)
        }
    }

    /// Updates one canonical parent/leaf relation and the paths affected by that relation.
    func renameProjectsByPrefix(oldPrefix: String, newPrefix: String, vaultId: UUID) throws -> ProjectRecord {
        try dbQueue.write { db in
            let records = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
            guard var project = records.first(where: { $0.name == oldPrefix }) else {
                throw ProjectWorkspaceError.projectNotFound
            }
            let components = newPrefix.split(separator: "/")
            guard let leafName = components.last else { throw ProjectWorkspaceError.invalidName }
            let parentPath = components.dropLast().joined(separator: "/")
            let parentId = parentPath.isEmpty
                ? nil
                : records.first(where: { $0.name == parentPath })?.id
            guard parentPath.isEmpty || parentId != nil else {
                throw ProjectWorkspaceError.projectNotFound
            }
            project.parentProjectId = parentId
            project.leafName = String(leafName)
            project.projectType = parentId == nil
                ? (ProjectRecord.effectiveType(for: project.id, records: records)?.type ?? .undefined)
                : nil
            project.revision += 1
            try project.update(db)

            let descendantIds = try Set(
                ProjectRecord.hierarchy(projectId: project.id, vaultId: vaultId, in: db)
                    .dropFirst()
                    .map(\.id)
            )
            try ProjectRecord.incrementRevisions(descendantIds, in: db)
            try SummaryExportRecord.renameVaultPathsByPrefix(
                oldPrefix: oldPrefix,
                newPrefix: newPrefix,
                vaultId: vaultId,
                in: db
            )
            guard let resolved = try ProjectRecord.fetchResolved(id: project.id, in: db) else {
                throw ProjectWorkspaceError.projectNotFound
            }
            return resolved
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
            let records = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
            guard let project = records.first(where: { $0.name == name }) else { return }
            let ids = try ProjectRecord.hierarchy(projectId: project.id, vaultId: vaultId, in: db)
                .reversed()
                .map(\.id)
            for id in ids {
                _ = try ProjectRecord.deleteOne(db, key: id)
            }
        }
    }

    /// 指定プレフィクスに一致するプロジェクトの missingOnDisk フラグをクリアする。
    func clearProjectsMissing(prefix: String, vaultId: UUID) throws {
        try dbQueue.write { db in
            try ProjectRecord.setMissingByPrefix(prefix, missing: false, vaultId: vaultId, in: db)
        }
    }

    @discardableResult
    func updateProjectDescription(id: UUID, vaultId: UUID, description: String) throws -> Bool {
        try dbQueue.write { db in
            guard var record = try ProjectRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db) else {
                return false
            }
            record.description = description
            record.revision += 1
            try record.update(db)
            return true
        }
    }

    func updateRootProjectType(id: UUID, vaultId: UUID, projectType: ProjectType) throws -> ProjectRecord {
        try dbQueue.write { db in
            guard var project = try ProjectRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db) else {
                throw ProjectWorkspaceError.projectNotFound
            }
            guard project.parentProjectId == nil else {
                throw ProjectWorkspaceError.typeOwnedByRoot
            }
            guard project.projectType != projectType else {
                return try ProjectRecord.fetchResolved(id: id, in: db) ?? project
            }
            project.projectType = projectType
            project.revision += 1
            try project.update(db)
            let descendantIds = try Set(
                ProjectRecord.hierarchy(projectId: id, vaultId: project.vaultId, in: db)
                    .dropFirst()
                    .map(\.id)
            )
            try ProjectRecord.incrementRevisions(descendantIds, in: db)
            return try ProjectRecord.fetchResolved(id: id, in: db) ?? project
        }
    }

    func deleteProjectHierarchy(
        name: String,
        vaultId: UUID,
        meetingDisposition: ProjectMeetingDisposition,
        vaultExportUpdates: [MeetingVaultExportUpdate] = [],
        managedAudioRootURL: URL = BatchAudioStorage.managedRootURL
    ) throws {
        let meetingIds = try dbQueue.read { db in
            let projectIds = try ProjectRecord.hierarchy(path: name, vaultId: vaultId, in: db).map(\.id)
            guard !projectIds.isEmpty else { return Set<UUID>() }
            return try UUID.fetchSet(
                db,
                sql: "SELECT id FROM meetings WHERE projectId IN (\(projectIds.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(projectIds)
            )
        }

        let audioTargets: [BatchAudioCleanupService.DeletionTarget]
        if meetingDisposition == .deleteMeetings {
            try ensureNoActiveSegmentedAudio(meetingIds: meetingIds)
            audioTargets = try BatchAudioCleanupService.deletionTargets(
                meetingIds: meetingIds,
                dbQueue: dbQueue
            ) + segmentedAudioDeletionTargets(
                meetingIds: meetingIds,
                managedRootURL: managedAudioRootURL
            )
        } else {
            audioTargets = []
        }
        let stagedAudio = try BatchAudioCleanupService.stageFiles(audioTargets)
        do {
            try dbQueue.write { db in
                let hierarchy = try ProjectRecord.hierarchy(path: name, vaultId: vaultId, in: db)
                guard !hierarchy.isEmpty else { return }
                let projectIds = Set(hierarchy.map(\.id))

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
                        try Self.updateVaultExports(vaultExportUpdates, forMeetingIds: meetingIds, in: db)
                    }
                case .deleteMeetings:
                    if !meetingIds.isEmpty {
                        _ = try MeetingRecord.filter(meetingIds.contains(Column("id"))).deleteAll(db)
                    }
                }

                for id in hierarchy.reversed().map(\.id) {
                    _ = try ProjectRecord.deleteOne(db, key: id)
                }
            }
        } catch {
            try BatchAudioCleanupService.restoreStagedFiles(stagedAudio)
            throw error
        }
        BatchAudioCleanupService.discardStagedFiles(stagedAudio)
    }

    private func ensureNoLiveSegmentedAudio(meetingIds: Set<UUID>) throws {
        guard !meetingIds.isEmpty else { return }
        let count = try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM recording_audio_segments
                JOIN recording_sessions
                  ON recording_sessions.id = recording_audio_segments.recordingSessionId
                WHERE recording_sessions.meetingId IN (\(meetingIds.map { _ in "?" }.joined(separator: ",")))
                  AND recording_audio_segments.state <> ?
                """,
                arguments: StatementArguments(meetingIds) + [RecordingAudioSegmentState.purged]
            ) ?? 0
        }
        guard count == 0 else { throw RecordingAudioStoreError.invalidState }
    }

    private func ensureNoActiveSegmentedAudio(meetingIds: Set<UUID>) throws {
        guard !meetingIds.isEmpty else { return }
        let count = try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM recording_audio_segments
                JOIN recording_sessions
                  ON recording_sessions.id = recording_audio_segments.recordingSessionId
                WHERE recording_sessions.meetingId IN (\(meetingIds.map { _ in "?" }.joined(separator: ",")))
                  AND recording_audio_segments.state IN (?, ?, ?)
                """,
                arguments: StatementArguments(meetingIds) + [
                    RecordingAudioSegmentState.recording,
                    RecordingAudioSegmentState.finalizing,
                    RecordingAudioSegmentState.purgePending,
                ]
            ) ?? 0
        }
        guard count == 0 else { throw RecordingAudioStoreError.invalidState }
    }

    private func segmentedAudioDeletionTargets(
        meetingIds: Set<UUID>,
        managedRootURL: URL
    ) throws -> [BatchAudioCleanupService.DeletionTarget] {
        guard !meetingIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            let paths = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT recording_audio_segments.finalRelativePath
                FROM recording_audio_segments
                JOIN recording_sessions
                  ON recording_sessions.id = recording_audio_segments.recordingSessionId
                WHERE recording_sessions.meetingId IN (\(meetingIds.map { _ in "?" }.joined(separator: ",")))
                  AND recording_audio_segments.state <> ?
                """,
                arguments: StatementArguments(meetingIds) + [RecordingAudioSegmentState.purged]
            )
            return paths.map {
                BatchAudioCleanupService.DeletionTarget(
                    baseURL: managedRootURL,
                    relativePath: $0
                )
            }
        }
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

    private func recordingSessionIds(meetingIds: Set<UUID>) throws -> [UUID] {
        guard !meetingIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: """
                SELECT id
                FROM recording_sessions
                WHERE meetingId IN (\(meetingIds.map { _ in "?" }.joined(separator: ",")))
                """,
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
