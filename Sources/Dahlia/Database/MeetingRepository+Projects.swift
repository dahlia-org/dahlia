import Foundation
import GRDB

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

    func meetingIds(projectHierarchy name: String, vaultId: UUID) throws -> Set<UUID> {
        try dbQueue.read { db in
            let projectIds = try ProjectRecord.hierarchy(prefix: name, vaultId: vaultId, in: db).map(\.id)
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

    @discardableResult
    func updateProjectDescription(id: UUID, description: String) throws -> Bool {
        try dbQueue.write { db in
            guard var record = try ProjectRecord.fetchOne(db, key: id) else {
                return false
            }
            record.description = description
            try record.update(db)
            return true
        }
    }

    func deleteProjectHierarchy(
        name: String,
        vaultId: UUID,
        meetingDisposition: ProjectMeetingDisposition,
        vaultExportUpdates: [MeetingVaultExportUpdate] = []
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
                    try Self.updateVaultExports(vaultExportUpdates, forMeetingIds: meetingIds, in: db)
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
}
