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

    nonisolated static func updateVaultExports(
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

    private nonisolated static let generatedSummaryTagColorHex = "#808080"

    nonisolated let dbQueue: DatabaseQueue

    nonisolated init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Vaults

    /// 全保管庫を最終オープン日時の降順で取得する。
    nonisolated func fetchAllVaults() throws -> [VaultRecord] {
        try dbQueue.read { db in
            try VaultRecord.order(Column("lastOpenedAt").desc).fetchAll(db)
        }
    }

    /// UI をブロックせず、全保管庫を最終オープン日時の降順で取得する。
    nonisolated func fetchAllVaultsAsync() async throws -> [VaultRecord] {
        try await dbQueue.read { db in
            try VaultRecord.order(Column("lastOpenedAt").desc).fetchAll(db)
        }
    }

    /// 最後にオープンした保管庫を取得する。
    func fetchLastOpenedVault() throws -> VaultRecord? {
        try dbQueue.read { db in
            try VaultRecord
                .filter(Column("lastOpenedAt") != Date.distantPast)
                .order(Column("lastOpenedAt").desc)
                .fetchOne(db)
        }
    }

    /// 保管庫を登録する。
    nonisolated func insertVault(_ vault: VaultRecord) throws {
        try dbQueue.write { db in
            try vault.insert(db)
        }
    }

    /// UI をブロックせず、保管庫を登録する。
    nonisolated func insertVaultAsync(_ vault: VaultRecord) async throws {
        try await dbQueue.write { db in
            try vault.insert(db)
        }
    }

    /// 保管庫の表示名を更新する。
    nonisolated func updateVaultName(id: UUID, name: String) async throws -> VaultRecord? {
        try await dbQueue.write { db in
            guard var vault = try VaultRecord.fetchOne(db, key: id) else { return nil }
            vault.name = name
            try vault.update(db)
            return vault
        }
    }

    nonisolated func updateVaultAISettings(_ settings: VaultAISettingsSnapshot) async throws -> VaultRecord? {
        try await dbQueue.write { db in
            guard var vault = try VaultRecord.fetchOne(db, key: settings.vaultID) else { return nil }
            settings.applyAISettings(to: &vault)
            try vault.update(db)
            return vault
        }
    }

    nonisolated func updateVaultAccountConnection(id: UUID, connectionID: UUID?) async throws -> VaultRecord? {
        try await dbQueue.write { db in
            guard var vault = try VaultRecord.fetchOne(db, key: id) else { return nil }
            guard vault.syncDeletionMode == nil || vault.accountConnectionId == connectionID else { return nil }
            if vault.accountConnectionId != connectionID {
                vault.syncEnabled = false
                vault.syncConfirmedConnectionId = nil
                try db.execute(
                    sql: """
                    UPDATE screenshots SET syncUploadedConnectionId = NULL
                    WHERE meetingId IN (SELECT id FROM meetings WHERE vaultId = ?)
                    """,
                    arguments: [id]
                )
            }
            vault.accountConnectionId = connectionID
            try vault.update(db)
            return vault
        }
    }

    nonisolated func updateVaultSync(id: UUID, isEnabled: Bool) async throws -> VaultRecord? {
        try await dbQueue.write { db in
            guard var vault = try VaultRecord.fetchOne(db, key: id),
                  !isEnabled || vault.accountConnectionId != nil else { return nil }
            vault.syncEnabled = isEnabled
            vault.syncConfirmedConnectionId = isEnabled ? vault.accountConnectionId : vault.syncConfirmedConnectionId
            try vault.update(db)
            return vault
        }
    }

    nonisolated func requestServerVaultDeletion(id: UUID) async throws -> VaultRecord? {
        try await dbQueue.write { db in
            guard var vault = try VaultRecord.fetchOne(db, key: id),
                  let connectionId = vault.accountConnectionId else { return nil }
            vault.syncEnabled = false
            vault.syncDeletionMode = MeetingSyncDeletionMode.deleteOnly.rawValue
            vault.syncDeletionApproved = true
            vault.syncDeletionConnectionId = connectionId
            try db.execute(
                sql: """
                UPDATE screenshots SET syncUploadedConnectionId = NULL
                WHERE meetingId IN (SELECT id FROM meetings WHERE vaultId = ?)
                """,
                arguments: [id]
            )
            try vault.update(db)
            return vault
        }
    }

    nonisolated func pendingMeetingDeletionCounts() async throws -> [UUID: Int] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT vaultId, count(*) AS pendingCount FROM meeting_sync_jobs
                WHERE targetKind = 'meetingDelete'
                GROUP BY vaultId HAVING count(*) >= ?
                """,
                arguments: [MeetingSyncQueue.meetingDeleteConfirmationThreshold]
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["vaultId"] as UUID, $0["pendingCount"] as Int) })
        }
    }

    nonisolated func approvePendingMeetingDeletions(vaultId: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE vaults SET syncBulkDeleteApproved = 1 WHERE id = ?", arguments: [vaultId])
        }
    }

    nonisolated func backfillVaultAISettings(_ settings: VaultAISettingsLegacyValues) async throws {
        try await dbQueue.write { db in
            var vaults = try VaultRecord.filter(Column("aiSettingsBackfilled") == false).fetchAll(db)
            for index in vaults.indices {
                settings.apply(to: &vaults[index])
                vaults[index].aiSettingsBackfilled = true
                try vaults[index].update(db)
            }
        }
    }

    nonisolated func vaultCountsByAccountConnectionID() async throws -> [UUID: Int] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT accountConnectionId, COUNT(*) AS vaultCount
                FROM vaults
                WHERE accountConnectionId IS NOT NULL
                GROUP BY accountConnectionId
                """
            )
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let connectionID: UUID = row["accountConnectionId"] else { return nil }
                let count: Int = row["vaultCount"]
                return (connectionID, count)
            })
        }
    }

    /// 保管庫を登録解除する（関連プロジェクト・ミーティングもカスケード削除）。
    nonisolated func deleteVault(id: UUID) throws {
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

    private nonisolated static func deleteVaultRows(id: UUID, in db: Database) throws {
        let projects = try ProjectRecord.fetchResolvedAll(vaultId: id, in: db)
            .sorted {
                $0.path.split(separator: "/").count > $1.path.split(separator: "/").count
            }
        for project in projects {
            _ = try ProjectRecord.deleteOne(db, key: project.id)
        }
        _ = try VaultRecord.deleteOne(db, key: id)
    }

    nonisolated func deleteVaultSafely(
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

    /// UI をブロックせず、保管庫の最終オープン日時を更新する。
    nonisolated func updateVaultLastOpened(id: UUID) async throws -> VaultRecord? {
        try await dbQueue.write { db in
            guard var record = try VaultRecord.fetchOne(db, key: id) else { return nil }
            record.lastOpenedAt = .now
            try record.update(db)
            return record
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

    nonisolated func fetchMeeting(id: UUID) throws -> MeetingRecord? {
        try dbQueue.read { db in
            try MeetingRecord.fetchOne(db, key: id)
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
        expectedVaultId: UUID,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) async throws -> Bool {
        try await BatchTranscriptionDiscardService.discardUnprocessedSessionSafely(
            id: id,
            expectedVaultId: expectedVaultId,
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

    nonisolated func fetchMeetingMoveCandidates(ids: Set<UUID>, vaultId: UUID) throws -> [MeetingMoveCandidate] {
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

    nonisolated func externalVaultSummaryPaths(
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
                      destination.vaultId == vaultId
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

    nonisolated func applyGeneratedSummary(
        toMeetingId meetingId: UUID,
        document: SummaryDocument,
        tags: [String]
    ) throws {
        try dbQueue.write { db in
            guard var meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { return }

            let existingSummary = try SummaryRecord.fetchOne(db, key: meetingId)
            let normalizedTitle = SummaryGeneratedMetadata.normalizedTitle(document.title)
            if let normalizedTitle {
                meeting.name = normalizedTitle
            }
            if let description = SummaryGeneratedMetadata.normalizedDescription(document.description) {
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

    func updateSummaryGoogleFileId(
        forMeetingId meetingId: UUID,
        googleFileId: String?,
        expectedDocument: String
    ) throws -> Bool {
        try dbQueue.write { db in
            guard let summary = try SummaryRecord.fetchOne(db, key: meetingId),
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

    nonisolated func updateSummaryArtifactURL(
        forMeetingId meetingId: UUID,
        url: String,
        expectedDocument: String
    ) async throws -> Bool {
        try await dbQueue.write { db in
            guard let summary = try SummaryRecord.fetchOne(db, key: meetingId),
                  try summary.loadDocument().databaseJSONString() == expectedDocument else { return false }
            try SummaryExportRecord.setURL(url, meetingId: meetingId, type: .dahliaArtifact, in: db)
            return true
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
    /// 現在の Vault にある同一予定の最新 Meeting を返し、観測した予定情報も更新する。
    func resolveMeetingIdForCalendarEvent(
        _ event: CalendarEvent,
        vaultId: UUID,
        observedAt: Date = .now,
        customerIntelligenceIngestion: CustomerIntelligenceIngestionPolicy
    ) throws -> UUID? {
        guard let key = event.key else { return nil }
        let meetingId = try dbQueue.write { db in
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
        if customerIntelligenceIngestion == .afterMeetingPersistence, let meetingId {
            CustomerIntelligenceIngestionService.schedule(
                calendarEvent: event,
                meetingId: meetingId,
                vaultId: vaultId,
                observedAt: observedAt,
                dbQueue: dbQueue
            )
        }
        return meetingId
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

    private nonisolated func meetingIds(vaultId: UUID) throws -> [UUID] {
        try dbQueue.read { db in
            try UUID.fetchAll(db, sql: "SELECT id FROM meetings WHERE vaultId = ?", arguments: [vaultId])
        }
    }
}
