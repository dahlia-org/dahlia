import DahliaRuntimeSupport
import Foundation
import GRDB

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

    func prepareSegmentedAudioForProjectDeletion(
        name: String,
        vaultId: UUID,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) async throws {
        let ids = try await dbQueue.read { db in
            let projectIds = try ProjectRecord.hierarchy(path: name, vaultId: vaultId, in: db).map(\.id)
            guard !projectIds.isEmpty else { return Set<UUID>() }
            return try UUID.fetchSet(
                db,
                sql: "SELECT id FROM meetings WHERE projectId IN (\(projectIds.map { _ in "?" }.joined(separator: ",")))",
                arguments: StatementArguments(projectIds)
            )
        }
        try await prepareSegmentedAudioForDeletion(meetingIds: ids, managedRootURL: managedRootURL)
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
}
