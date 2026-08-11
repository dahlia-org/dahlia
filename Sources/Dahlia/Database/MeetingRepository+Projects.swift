import DahliaRuntimeSupport
import Foundation
import GRDB

// MARK: - Projects

extension MeetingRepository {
    /// 指定保管庫のプロジェクトを論理パス順で取得する。
    nonisolated func fetchAllProjects(vaultId: UUID) throws -> [ProjectRecord] {
        try dbQueue.read { db in
            try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
        }
    }

    nonisolated func meetingIds(projectHierarchy name: String, vaultId: UUID) throws -> Set<UUID> {
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

    nonisolated func fetchProject(id: UUID) throws -> ProjectRecord? {
        try dbQueue.read { db in
            try ProjectRecord.fetchResolved(id: id, in: db)
        }
    }

    func createProject(
        vaultId: UUID,
        parentProjectId: UUID?,
        name: String,
        description: String,
        projectType: ProjectType?
    ) throws -> ProjectRecord {
        try dbQueue.write { db in
            guard DahliaProjectName.normalizedName(name) == name else {
                throw ProjectWorkspaceError.invalidName
            }
            if let parentProjectId {
                guard let parent = try ProjectRecord.fetchOne(db, key: parentProjectId),
                      parent.vaultId == vaultId else {
                    throw ProjectWorkspaceError.projectNotFound
                }
                guard parent.parentProjectId == nil else {
                    throw ProjectWorkspaceError.hierarchyTooDeep
                }
                guard projectType == nil else {
                    throw ProjectWorkspaceError.typeOwnedByRoot
                }
            }
            let record = ProjectRecord(
                id: .v7(),
                vaultId: vaultId,
                parentProjectId: parentProjectId,
                name: name,
                createdAt: .now,
                description: description,
                projectType: parentProjectId == nil ? (projectType ?? .undefined) : nil
            )
            try record.insert(db)
            return try ProjectRecord.fetchResolved(id: record.id, in: db) ?? record
        }
    }

    nonisolated func createCustomerIntelligenceProject(
        vaultId: UUID,
        parentProjectId: UUID?,
        name: String,
        description: String,
        projectType: ProjectType?,
        organizationId: UUID,
        now: Date = .now
    ) throws -> ProjectRecord {
        try dbQueue.write { db in
            guard DahliaProjectName.normalizedName(name) == name else {
                throw ProjectWorkspaceError.invalidName
            }
            guard let organization = try OrganizationRecord.fetchOne(db, key: organizationId),
                  organization.vaultId == vaultId else {
                throw CustomerIntelligenceError.invalidReference
            }
            if let parentProjectId {
                guard let parent = try ProjectRecord.fetchOne(db, key: parentProjectId),
                      parent.vaultId == vaultId else {
                    throw ProjectWorkspaceError.projectNotFound
                }
                guard parent.parentProjectId == nil else {
                    throw ProjectWorkspaceError.hierarchyTooDeep
                }
                guard projectType == nil else {
                    throw ProjectWorkspaceError.typeOwnedByRoot
                }
            }
            guard try ProjectRecord
                .filter(
                    Column("vaultId") == vaultId
                        && Column("parentProjectId") == parentProjectId
                        && Column("nameKey") == DahliaProjectName.siblingKey(name)
                )
                .fetchOne(db) == nil else {
                throw ProjectWorkspaceError.projectAlreadyExists(name)
            }

            let project = ProjectRecord(
                id: .v7(),
                vaultId: vaultId,
                parentProjectId: parentProjectId,
                name: name,
                createdAt: now,
                description: description,
                projectType: parentProjectId == nil ? (projectType ?? .undefined) : nil
            )
            try project.insert(db)
            try ProjectResourceReferenceRecord(
                id: .v7(),
                projectId: project.id,
                resourceType: .organization,
                resourceId: organizationId,
                relationLabel: "",
                createdAt: now,
                updatedAt: now
            ).insert(db)
            return try ProjectRecord.fetchResolved(id: project.id, in: db) ?? project
        }
    }

    nonisolated func updateCustomerIntelligenceProject(
        id: UUID,
        vaultId: UUID,
        parentProjectId: UUID?,
        name: String,
        description: String,
        projectType: ProjectType,
        vaultExportUpdates: [MeetingVaultExportUpdate],
        expectedRevision: Int
    ) throws -> ProjectRecord {
        try dbQueue.write { db in
            let records = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
            guard var project = records.first(where: { $0.id == id }) else {
                throw ProjectWorkspaceError.projectNotFound
            }
            guard project.revision == expectedRevision else {
                throw ProjectWorkspaceError.staleRevision(current: project.revision)
            }
            guard DahliaProjectName.normalizedName(name) == name else {
                throw ProjectWorkspaceError.invalidName
            }
            let descendants = records.filter {
                $0.id != id && ProjectRecord.belongsToHierarchy($0.path, prefix: project.path)
            }
            let descendantIDs = Set(descendants.map(\.id))
            guard parentProjectId != id,
                  parentProjectId.map({ !descendantIDs.contains($0) }) ?? true else {
                throw ProjectWorkspaceError.cycleDetected
            }
            if let parentProjectId {
                guard let parent = records.first(where: { $0.id == parentProjectId }) else {
                    throw ProjectWorkspaceError.projectNotFound
                }
                guard parent.parentProjectId == nil, descendants.isEmpty else {
                    throw ProjectWorkspaceError.hierarchyTooDeep
                }
            }
            guard !records.contains(where: {
                $0.id != id
                    && $0.parentProjectId == parentProjectId
                    && $0.nameKey == DahliaProjectName.siblingKey(name)
            }) else {
                throw ProjectWorkspaceError.projectAlreadyExists(name)
            }

            let locationChanged = project.parentProjectId != parentProjectId || project.name != name
            let typeChanged = parentProjectId == nil && project.projectType != projectType
            let changed = locationChanged || typeChanged || project.description != description
            guard changed else { return project }

            project.parentProjectId = parentProjectId
            project.name = name
            project.description = description
            project.projectType = parentProjectId == nil ? projectType : nil
            project.revision += 1
            try project.update(db)
            if locationChanged || typeChanged {
                try ProjectRecord.incrementRevisions(descendantIDs, in: db)
            }
            let meetingIds = Set(vaultExportUpdates.map(\.meetingId))
            try Self.updateVaultExports(
                vaultExportUpdates,
                forMeetingIds: meetingIds,
                in: db
            )
            guard let resolved = try ProjectRecord.fetchResolved(id: id, in: db) else {
                throw ProjectWorkspaceError.projectNotFound
            }
            return resolved
        }
    }

    /// 指定名のプロジェクトを取得し、存在しなければ作成して返す。
    func fetchOrCreateProject(name: String, vaultId: UUID) throws -> ProjectRecord {
        try dbQueue.write { db in
            guard let name = DahliaProjectName.normalizedName(name) else {
                throw ProjectWorkspaceError.invalidName
            }
            let siblingKey = DahliaProjectName.siblingKey(name)
            if let existing = try ProjectRecord
                .filter(
                    Column("vaultId") == vaultId
                        && Column("parentProjectId") == nil
                        && Column("nameKey") == siblingKey
                )
                .fetchOne(db) {
                return try ProjectRecord.fetchResolved(id: existing.id, in: db) ?? existing
            }
            let project = ProjectRecord(
                id: .v7(),
                vaultId: vaultId,
                parentProjectId: nil,
                name: name,
                createdAt: .now,
                projectType: .undefined
            )
            try project.insert(db)
            return try ProjectRecord.fetchResolved(id: project.id, in: db) ?? project
        }
    }

    /// Updates one canonical parent/name relation without deriving identity from a path or directory.
    func updateProjectLocation(
        id: UUID,
        vaultId: UUID,
        parentProjectId: UUID?,
        name: String,
        vaultExportUpdates: [MeetingVaultExportUpdate],
        expectedRevision: Int? = nil
    ) throws -> ProjectRecord {
        try dbQueue.write { db in
            let records = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
            guard var project = records.first(where: { $0.id == id }) else {
                throw ProjectWorkspaceError.projectNotFound
            }
            if let expectedRevision, project.revision != expectedRevision {
                throw ProjectWorkspaceError.staleRevision(current: project.revision)
            }
            guard DahliaProjectName.normalizedName(name) == name else {
                throw ProjectWorkspaceError.invalidName
            }
            if let parentProjectId {
                guard parentProjectId != id else {
                    throw ProjectWorkspaceError.cycleDetected
                }
                guard let parent = records.first(where: { $0.id == parentProjectId }) else {
                    throw ProjectWorkspaceError.projectNotFound
                }
                guard parent.parentProjectId == nil,
                      !records.contains(where: { $0.parentProjectId == project.id }) else {
                    throw ProjectWorkspaceError.hierarchyTooDeep
                }
            }
            guard !records.contains(where: {
                $0.id != id
                    && $0.parentProjectId == parentProjectId
                    && $0.nameKey == DahliaProjectName.siblingKey(name)
            }) else {
                throw ProjectWorkspaceError.projectAlreadyExists(name)
            }

            let effectiveType = ProjectRecord.effectiveType(for: project.id, records: records)?.type ?? .undefined
            let wasRoot = project.parentProjectId == nil
            project.parentProjectId = parentProjectId
            project.name = name
            project.projectType = parentProjectId == nil
                ? (wasRoot ? project.projectType ?? .undefined : effectiveType)
                : nil
            project.revision += 1
            try project.update(db)

            let descendantIds = try Set(
                ProjectRecord.hierarchy(projectId: project.id, vaultId: vaultId, in: db)
                    .dropFirst()
                    .map(\.id)
            )
            try ProjectRecord.incrementRevisions(descendantIds, in: db)
            let meetingIds = Set(vaultExportUpdates.map(\.meetingId))
            try Self.updateVaultExports(
                vaultExportUpdates,
                forMeetingIds: meetingIds,
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

    @discardableResult
    func updateProjectDescription(
        id: UUID,
        vaultId: UUID,
        description: String,
        expectedRevision: Int? = nil
    ) throws -> Bool {
        try dbQueue.write { db in
            guard var record = try ProjectRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db) else {
                return false
            }
            if let expectedRevision, record.revision != expectedRevision {
                throw ProjectWorkspaceError.staleRevision(current: record.revision)
            }
            record.description = description
            record.revision += 1
            try record.update(db)
            return true
        }
    }

    func updateRootProjectType(
        id: UUID,
        vaultId: UUID,
        projectType: ProjectType,
        expectedRevision: Int? = nil
    ) throws -> ProjectRecord {
        try dbQueue.write { db in
            guard var project = try ProjectRecord
                .filter(Column("id") == id && Column("vaultId") == vaultId)
                .fetchOne(db) else {
                throw ProjectWorkspaceError.projectNotFound
            }
            if let expectedRevision, project.revision != expectedRevision {
                throw ProjectWorkspaceError.staleRevision(current: project.revision)
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
        managedAudioRootURL: URL = BatchAudioStorage.managedRootURL,
        restoreStagedAudio: ([BatchAudioCleanupService.StagedFile]) throws -> Void =
            BatchAudioCleanupService.restoreStagedFiles
    ) throws -> [BatchAudioCleanupService.StagedFile] {
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
        let segmentedAudioLease: RecordingAudioStore.ParentDeletionLease?
        if meetingDisposition == .deleteMeetings {
            segmentedAudioLease = try RecordingAudioStore.acquireParentDeletionLease(
                sessions: recordingSessionsForParentDeletion(meetingIds: meetingIds),
                managedRootURL: managedAudioRootURL
            )
            try ensureNoActiveSegmentedAudio(meetingIds: meetingIds)
            audioTargets = try BatchAudioCleanupService.deletionTargets(
                meetingIds: meetingIds,
                dbQueue: dbQueue
            ) + segmentedAudioDeletionTargets(
                meetingIds: meetingIds,
                managedRootURL: managedAudioRootURL
            )
        } else {
            segmentedAudioLease = nil
            audioTargets = []
        }
        defer { withExtendedLifetime(segmentedAudioLease) {} }
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
        } catch let operationError {
            do {
                try restoreStagedAudio(stagedAudio)
            } catch let rollbackError {
                throw ProjectWorkspaceError.rollbackFailed(
                    operation: operationError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw operationError
        }
        return stagedAudio
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

    private func recordingSessionsForParentDeletion(
        meetingIds: Set<UUID>
    ) throws -> [RecordingAudioStore.ParentDeletionSession] {
        guard !meetingIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT recording_sessions.id, recording_sessions.meetingId
                FROM recording_sessions
                JOIN recording_audio_segments
                  ON recording_audio_segments.recordingSessionId = recording_sessions.id
                WHERE recording_sessions.meetingId IN (\(meetingIds.map { _ in "?" }.joined(separator: ",")))
                """,
                arguments: StatementArguments(meetingIds)
            ).map { row in
                RecordingAudioStore.ParentDeletionSession(
                    meetingId: row["meetingId"],
                    sessionId: row["id"]
                )
            }
        }
    }
}
