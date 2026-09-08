import DahliaRuntimeSupport
import Foundation
import GRDB

enum RemoteChangeApplier {
    static func recoveryGeneration(vaultId: UUID, expectedConnectionId: UUID, dbQueue: DatabaseQueue) async throws -> Int64? {
        try await dbQueue.read { db in
            guard try SyncTransactionQueue.matchesExpectedConnection(vaultId: vaultId, connectionId: expectedConnectionId, in: db),
                  try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db),
                  try !hasActiveRecording(in: db) else { return nil }
            return try Int64.fetchOne(db, sql: "SELECT syncMutationGeneration FROM vaults WHERE id = ?", arguments: [vaultId])
        }
    }

    private static func withCurrentAssociation(
        vaultId: UUID,
        expectedConnectionId: UUID,
        dbQueue: DatabaseQueue,
        expectedMutationGeneration: Int64? = nil,
        incrementalContext: RemoteChangePolicy.Context? = nil,
        _ body: @Sendable (Database) throws -> Bool
    ) async throws -> Bool {
        try await dbQueue.write { db in
            guard try SyncTransactionQueue.matchesExpectedConnection(
                vaultId: vaultId,
                connectionId: expectedConnectionId,
                in: db
            ) else { return false }
            if let incrementalContext {
                guard try incrementalContext.isCurrent(in: db) else { return false }
            } else if let expectedMutationGeneration {
                guard try Int64.fetchOne(
                    db, sql: "SELECT syncMutationGeneration FROM vaults WHERE id = ?", arguments: [vaultId]
                ) == expectedMutationGeneration, try !hasActiveRecording(in: db) else { return false }
            }
            return try body(db)
        }
    }

    private static func withStagedAudioDeletion(
        meetingIds: Set<UUID>,
        vaultId: UUID,
        expectedConnectionId: UUID,
        dbQueue: DatabaseQueue,
        expectedMutationGeneration: Int64? = nil,
        incrementalContext: RemoteChangePolicy.Context? = nil,
        _ body: () async throws -> Bool
    ) async throws -> Bool {
        guard !meetingIds.isEmpty else { return try await body() }
        let preflight = try await withCurrentAssociation(
            vaultId: vaultId,
            expectedConnectionId: expectedConnectionId,
            dbQueue: dbQueue,
            expectedMutationGeneration: expectedMutationGeneration,
            incrementalContext: incrementalContext
        ) { db in
            if incrementalContext != nil {
                return try meetingIds.allSatisfy { try RemoteChangePolicy.permits(.meeting, id: $0, action: "delete", vaultId: vaultId, in: db) }
            }
            return try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db) && !hasActiveRecording(in: db)
        }
        guard preflight else { return false }

        let sessions = try await dbQueue.read { db in
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
                RecordingAudioStore.ParentDeletionSession(meetingId: row["meetingId"], sessionId: row["id"])
            }
        }
        let lease = try RecordingAudioStore.acquireParentDeletionLease(
            sessions: sessions,
            managedRootURL: BatchAudioStorage.managedRootURL
        )
        defer { withExtendedLifetime(lease) {} }
        let segmentedTargets = try await dbQueue.read { db in
            try String.fetchAll(
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
            ).map {
                BatchAudioCleanupService.DeletionTarget(
                    baseURL: BatchAudioStorage.managedRootURL,
                    relativePath: $0
                )
            }
        }
        let targets = try BatchAudioCleanupService.deletionTargets(
            meetingIds: meetingIds,
            dbQueue: dbQueue
        ) + segmentedTargets
        let stagedFiles = try BatchAudioCleanupService.stageFiles(targets)
        let applied: Bool
        do {
            applied = try await body()
        } catch let operationError {
            do {
                try BatchAudioCleanupService.restoreStagedFiles(stagedFiles)
            } catch let rollbackError {
                throw ProjectWorkspaceError.rollbackFailed(
                    operation: operationError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw operationError
        }
        if applied {
            try BatchAudioCleanupService.discardStagedFiles(stagedFiles)
        } else {
            try BatchAudioCleanupService.restoreStagedFiles(stagedFiles)
        }
        return applied
    }

    static func reconcileRecoveryProjects(
        _ projects: [SyncProjectSnapshot],
        vaultId: UUID,
        expectedConnectionId: UUID,
        dbQueue: DatabaseQueue,
        generation: Int64
    ) async throws -> Bool {
        let existing = try await dbQueue.read { db in
            try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
        }
        let incomingIDs = Set(projects.map(\.projectId))
        let existingChildren = Set(existing.filter { $0.parentProjectId != nil }.map(\.id))
        let roots = projects.filter { $0.parentProjectId == nil }
        let movedChildren = projects.filter { $0.parentProjectId != nil && existingChildren.contains($0.projectId) }
        let newChildren = projects.filter { $0.parentProjectId != nil && !existingChildren.contains($0.projectId) }
        let missing = existing.filter { !incomingIDs.contains($0.id) }
        enum Step {
            case apply([SyncProjectSnapshot])
            case remove([UUID])
        }
        // Promote roots, move children, then demote roots. Missing children must not block demotion.
        let steps: [Step] = [
            .apply(roots),
            .remove(missing.filter { $0.parentProjectId != nil }.map(\.id)),
            .apply(movedChildren),
            .remove(missing.filter { $0.parentProjectId == nil }.map(\.id)),
            .apply(newChildren),
        ]
        for step in steps {
            switch step {
            case let .remove(ids):
                for start in stride(from: 0, to: ids.count, by: 100) {
                    let batch = Array(ids[start ..< min(start + 100, ids.count)])
                    guard try await withCurrentAssociation(
                        vaultId: vaultId, expectedConnectionId: expectedConnectionId, dbQueue: dbQueue,
                        expectedMutationGeneration: generation,
                        { db in
                            guard try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db) else { return false }
                            for id in batch {
                                try ProjectRecord.deleteOne(db, key: id)
                            }
                            return true
                        }
                    ) else { return false }
                }
            case let .apply(values):
                for start in stride(from: 0, to: values.count, by: 100) {
                    guard try await reconcileProjectSnapshot(
                        Array(values[start ..< min(start + 100, values.count)]), vaultId: vaultId,
                        expectedConnectionId: expectedConnectionId, dbQueue: dbQueue,
                        expectedMutationGeneration: generation, removeMissing: false
                    ) else { return false }
                }
            }
        }
        return true
    }

    static func reconcileProjectSnapshot(
        _ projects: [SyncProjectSnapshot],
        vaultId: UUID,
        expectedConnectionId: UUID,
        dbQueue: DatabaseQueue,
        expectedMutationGeneration: Int64? = nil,
        removeMissing: Bool = true,
        incrementalContext: RemoteChangePolicy.Context? = nil
    ) async throws -> Bool {
        let orderedProjects = removeMissing ? orderProjects(projects) : projects
        return try await withCurrentAssociation(
            vaultId: vaultId,
            expectedConnectionId: expectedConnectionId,
            dbQueue: dbQueue,
            expectedMutationGeneration: expectedMutationGeneration,
            incrementalContext: incrementalContext
        ) { db in
            let existing = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
            let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let incomingIDs = Set(projects.map(\.projectId))
            let removedIDs = removeMissing ? Set(existingByID.keys).subtracting(incomingIDs) : []
            if incrementalContext != nil {
                for project in projects {
                    guard try RemoteChangePolicy.permits(.project, id: project.projectId, vaultId: vaultId, in: db) else { return false }
                    if let revision = try Int.fetchOne(
                        db,
                        sql: "SELECT confirmedRevision FROM sync_entity_state WHERE vaultId = ? AND entity = 'project' AND entityId = ?",
                        arguments: [vaultId, project.projectId]
                    ), revision > project.revision { return false }
                }
                for id in removedIDs {
                    guard try RemoteChangePolicy.permits(.project, id: id, action: "delete", vaultId: vaultId, in: db) else { return false }
                }
            } else {
                guard try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db), try !hasActiveRecording(in: db) else { return false }
            }

            // Keep retained rows in place so local-only CRM references survive canonical refreshes.
            let roots = orderedProjects.filter { $0.parentProjectId == nil }
            let children = orderedProjects.filter { $0.parentProjectId != nil }
            for project in roots where existingByID[project.projectId] != nil {
                try db.execute(
                    sql: "UPDATE projects SET parentProjectId = NULL, projectType = ? WHERE id = ? AND vaultId = ?",
                    arguments: [project.projectType, project.projectId, vaultId]
                )
            }
            for project in roots where existingByID[project.projectId] == nil {
                try insert(project, vaultId: vaultId, in: db)
            }
            for project in existing where removedIDs.contains(project.id) && project.parentProjectId != nil {
                try ProjectRecord.deleteOne(db, key: project.id)
            }
            for project in children where existingByID[project.projectId]?.parentProjectId != nil {
                try db.execute(
                    sql: "UPDATE projects SET parentProjectId = ?, projectType = NULL WHERE id = ? AND vaultId = ?",
                    arguments: [project.parentProjectId, project.projectId, vaultId]
                )
            }
            for project in existing where removedIDs.contains(project.id) && project.parentProjectId == nil {
                try ProjectRecord.deleteOne(db, key: project.id)
            }
            for project in children where existingByID[project.projectId]?.parentProjectId == nil {
                try db.execute(
                    sql: "UPDATE projects SET parentProjectId = ?, projectType = NULL WHERE id = ? AND vaultId = ?",
                    arguments: [project.parentProjectId, project.projectId, vaultId]
                )
            }
            for project in children where existingByID[project.projectId] == nil {
                try insert(project, vaultId: vaultId, in: db)
            }

            for project in orderedProjects {
                let previous = existingByID[project.projectId]
                try ProjectRecord.applyCanonical(
                    id: project.projectId,
                    vaultId: vaultId,
                    parentProjectId: project.parentProjectId,
                    name: project.name,
                    createdAt: project.createdAt,
                    description: project.description,
                    projectType: project.projectType.flatMap(ProjectType.init(rawValue:)),
                    in: db
                )
                if let previous {
                    let hierarchyWasPreapplied = previous.parentProjectId != project.parentProjectId
                        || previous.projectType?.rawValue != project.projectType
                    if previous.name == project.name, hierarchyWasPreapplied {
                        var invalidatedIDs = Set(
                            ProjectRecord.hierarchy(projectId: previous.id, records: existing)
                                .dropFirst()
                                .map(\.id)
                        )
                        if previous.createdAt == project.createdAt,
                           previous.description == project.description {
                            invalidatedIDs.insert(previous.id)
                        }
                        try ProjectRecord.incrementRevisions(invalidatedIDs, in: db)
                    }
                }
                try db.execute(
                    sql: """
                    INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision)
                    VALUES (?, 'project', ?, ?)
                    ON CONFLICT(vaultId, entity, entityId) DO UPDATE SET
                        confirmedRevision = excluded.confirmedRevision
                    """,
                    arguments: [vaultId, project.projectId, project.revision]
                )
            }
            try db.execute(
                sql: "DELETE FROM sync_entity_state WHERE vaultId = ? AND entity = 'project' AND entityId NOT IN (SELECT id FROM projects WHERE vaultId = ?)",
                arguments: [vaultId, vaultId]
            )
            return true
        }
    }

    private static func insert(_ project: SyncProjectSnapshot, vaultId: UUID, in db: Database) throws {
        try ProjectRecord(
            id: project.projectId,
            vaultId: vaultId,
            parentProjectId: project.parentProjectId,
            name: project.name,
            createdAt: project.createdAt,
            description: project.description,
            projectType: project.projectType.flatMap(ProjectType.init(rawValue:))
        ).insert(db)
    }

    private static func hasActiveRecording(in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS (SELECT 1 FROM recording_sessions WHERE endedAt IS NULL)"
        ) ?? false
    }

    static func beginTranscript(
        meetingId: UUID,
        vaultId: UUID,
        expectedConnectionId: UUID,
        dbQueue: DatabaseQueue,
        expectedMutationGeneration: Int64? = nil,
        incrementalContext: RemoteChangePolicy.Context? = nil
    ) async throws -> Bool {
        try await withCurrentAssociation(
            vaultId: vaultId,
            expectedConnectionId: expectedConnectionId,
            dbQueue: dbQueue,
            expectedMutationGeneration: expectedMutationGeneration,
            incrementalContext: incrementalContext
        ) { db in
            if incrementalContext != nil {
                guard try RemoteChangePolicy.permits(.transcript, id: meetingId, vaultId: vaultId, in: db) else { return false }
            } else {
                guard try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db), try !hasActiveRecording(in: db) else { return false }
            }
            try db.execute(sql: """
            CREATE TEMP TABLE IF NOT EXISTS sync_remote_transcript_items (
                meetingId BLOB NOT NULL,
                segmentId BLOB NOT NULL,
                startedAt DATETIME NOT NULL,
                endedAt DATETIME,
                text TEXT NOT NULL,
                createdAt DATETIME,
                audioSource TEXT,
                speakerLabel TEXT,
                PRIMARY KEY (meetingId, segmentId)
            ) WITHOUT ROWID
            """)
            try db.execute(
                sql: "DELETE FROM sync_remote_transcript_items WHERE meetingId = ?",
                arguments: [meetingId]
            )
            return true
        }
    }

    static func applyTranscriptPage(
        _ segments: [SyncTranscriptPage.Segment],
        meetingId: UUID,
        vaultId: UUID,
        expectedConnectionId: UUID,
        dbQueue: DatabaseQueue,
        expectedMutationGeneration: Int64? = nil,
        incrementalContext: RemoteChangePolicy.Context? = nil
    ) async throws -> Bool {
        try await withCurrentAssociation(
            vaultId: vaultId,
            expectedConnectionId: expectedConnectionId,
            dbQueue: dbQueue,
            expectedMutationGeneration: expectedMutationGeneration,
            incrementalContext: incrementalContext
        ) { db in
            if incrementalContext != nil {
                guard try RemoteChangePolicy.permits(.transcript, id: meetingId, vaultId: vaultId, in: db) else { return false }
            } else {
                guard try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db), try !hasActiveRecording(in: db) else { return false }
            }
            for segment in segments {
                try db.execute(
                    sql: """
                    INSERT INTO sync_remote_transcript_items(
                        meetingId, segmentId, startedAt, endedAt, text,
                        createdAt, audioSource, speakerLabel
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(meetingId, segmentId) DO UPDATE SET
                        startedAt = excluded.startedAt,
                        endedAt = excluded.endedAt,
                        text = excluded.text,
                        createdAt = excluded.createdAt,
                        audioSource = excluded.audioSource,
                        speakerLabel = excluded.speakerLabel
                    """,
                    arguments: [
                        meetingId, segment.segmentId, segment.startedAt, segment.endedAt,
                        segment.text, segment.createdAt, segment.audioSource, segment.speakerLabel,
                    ]
                )
            }
            return true
        }
    }

    static func installStagedTranscript(meetingId: UUID, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO transcript_segments(
                id, meetingId, startedAt, endedAt, createdAt, audioSource, speakerLabel
            )
            SELECT segmentId, meetingId, startedAt, endedAt,
                createdAt, audioSource, speakerLabel
            FROM sync_remote_transcript_items
            WHERE meetingId = ?
            ON CONFLICT(id) DO UPDATE SET
                meetingId = excluded.meetingId,
                startedAt = excluded.startedAt,
                endedAt = excluded.endedAt,
                createdAt = excluded.createdAt,
                audioSource = excluded.audioSource,
                speakerLabel = excluded.speakerLabel
            """,
            arguments: [meetingId]
        )
        try db.execute(sql: """
        INSERT INTO transcript_segment_bodies(segmentId, text)
        SELECT segmentId, text FROM sync_remote_transcript_items WHERE meetingId = ?
        ON CONFLICT(segmentId) DO UPDATE SET text = excluded.text
        """, arguments: [meetingId])
        try db.execute(
            sql: """
            DELETE FROM transcript_segments
            WHERE meetingId = ?
              AND NOT EXISTS (
                  SELECT 1 FROM sync_remote_transcript_items remote
                  WHERE remote.meetingId = transcript_segments.meetingId
                    AND remote.segmentId = transcript_segments.id
              )
            """,
            arguments: [meetingId]
        )
    }

    private static func orderProjects(_ projects: [SyncProjectSnapshot]) -> [SyncProjectSnapshot] {
        let roots = projects.filter { $0.parentProjectId == nil }
            .sorted { $0.projectId.uuidString < $1.projectId.uuidString }
        let rootIds = Set(roots.map(\.projectId))
        let children = projects.filter { project in
            project.parentProjectId.map(rootIds.contains) == true
        }.sorted { $0.projectId.uuidString < $1.projectId.uuidString }
        return roots + children
    }

    static func applyIncremental(
        _ change: SyncChangePage.Change,
        context: RemoteChangePolicy.Context,
        dbQueue: DatabaseQueue
    ) async throws -> RemoteChangePolicy.Result {
        try Task.checkCancellation()
        let decision = try await dbQueue.read { try RemoteChangePolicy.decision(change, context: context, in: $0) }
        guard decision == .applied else { return decision }
        if try await apply(
            [change],
            screenshots: [:],
            transcripts: [:],
            cursor: nil,
            vaultId: context.vaultId,
            expectedConnectionId: context.connectionId,
            dbQueue: dbQueue,
            incrementalContext: context
        ) { return .applied }
        return try await dbQueue.read { try context.isCurrent(in: $0) ? .deferred : .retry }
    }

    static func advanceIncrementalCursor(
        _ cursor: String,
        from previous: String?,
        context: RemoteChangePolicy.Context,
        dbQueue: DatabaseQueue
    ) async throws -> Bool {
        try await dbQueue.write { db in
            guard try context.isCurrent(in: db),
                  try String.fetchOne(db, sql: "SELECT syncPullCursor FROM vaults WHERE id = ?", arguments: [context.vaultId]) == previous
            else { return false }
            try db.execute(sql: "UPDATE vaults SET syncPullCursor = ? WHERE id = ?", arguments: [cursor, context.vaultId])
            return true
        }
    }

    static func apply(
        _ changes: [SyncChangePage.Change],
        screenshots: [UUID: Data],
        transcripts: [UUID: [SyncTranscriptPage.Segment]],
        cursor: String?,
        vaultId: UUID,
        expectedConnectionId: UUID,
        dbQueue: DatabaseQueue,
        expectedMutationGeneration: Int64? = nil,
        incrementalContext: RemoteChangePolicy.Context? = nil
    ) async throws -> Bool {
        let deletedMeetingIds = Set(changes.compactMap { change in
            change.entity == .meeting && change.action == "delete" ? change.entityId : nil
        })
        return try await withStagedAudioDeletion(
            meetingIds: deletedMeetingIds,
            vaultId: vaultId,
            expectedConnectionId: expectedConnectionId,
            dbQueue: dbQueue,
            expectedMutationGeneration: expectedMutationGeneration,
            incrementalContext: incrementalContext
        ) {
            try await withCurrentAssociation(
                vaultId: vaultId,
                expectedConnectionId: expectedConnectionId,
                dbQueue: dbQueue,
                expectedMutationGeneration: expectedMutationGeneration,
                incrementalContext: incrementalContext
            ) { db in
                try Task.checkCancellation()
                if incrementalContext == nil {
                    guard try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db) else { return false }
                }
                if incrementalContext == nil, changes.contains(where: { $0.entity == .transcript }), try hasActiveRecording(in: db) {
                    return false
                }
                if changes.contains(where: { $0.action == "reset" && $0.record != nil }),
                   try hasActiveRecording(in: db) {
                    return false
                }
                let deletingActiveMeeting = try changes.contains { change in
                    guard change.entity == .meeting, change.action == "delete" else { return false }
                    return try Bool.fetchOne(
                        db,
                        sql: """
                        SELECT EXISTS (
                            SELECT 1 FROM recording_sessions
                            WHERE meetingId = ? AND endedAt IS NULL
                        )
                        """,
                        arguments: [change.entityId]
                    ) ?? false
                }
                guard !deletingActiveMeeting else { return false }
                for change in changes {
                    if let incrementalContext {
                        switch try RemoteChangePolicy.decision(change, context: incrementalContext, in: db) {
                        case .alreadyApplied: continue
                        case .deferred, .retry: return false
                        case .applied: break
                        }
                    }
                    if change.action == "delete" {
                        try delete(change.entity, id: change.entityId, vaultId: vaultId, in: db)
                    } else if change.action == "reset" {
                        if let record = change.record {
                            try SyncTransactionQueue.discard(vaultId: vaultId, in: db)
                            try db.execute(sql: "DELETE FROM sync_entity_state WHERE vaultId = ?", arguments: [vaultId])
                            try upsert(change, record: record, screenshots: screenshots, transcripts: transcripts, vaultId: vaultId, in: db)
                        } else {
                            try forgetRemoteVault(vaultId: vaultId, in: db)
                            return true
                        }
                    } else if let record = change.record {
                        try upsert(change, record: record, screenshots: screenshots, transcripts: transcripts, vaultId: vaultId, in: db)
                    }
                    try db.execute(
                        sql: """
                        INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(vaultId, entity, entityId) DO UPDATE SET
                            confirmedRevision = excluded.confirmedRevision
                        """,
                        arguments: [vaultId, change.entity, change.entityId, change.revision]
                    )
                }
                if let cursor {
                    try db.execute(sql: "UPDATE vaults SET syncPullCursor = ? WHERE id = ?", arguments: [cursor, vaultId])
                }
                return true
            }
        }
    }

    static func finishReset(
        _ snapshot: SyncResetSnapshot,
        cursor: String?,
        vaultId: UUID,
        expectedConnectionId: UUID,
        dbQueue: DatabaseQueue,
        expectedMutationGeneration: Int64? = nil
    ) async throws -> Bool {
        struct Existing {
            let projects: [ProjectRecord]
            let meetings: Set<UUID>
            let summaries: Set<UUID>
            let transcripts: Set<UUID>
            let screenshots: Set<UUID>
            let files: Set<UUID>
            let recordings: Set<UUID>
        }
        let existing = try await dbQueue.read { db in
            try Existing(
                projects: ProjectRecord.filter(Column("vaultId") == vaultId).fetchAll(db),
                meetings: Set(UUID.fetchAll(
                    db,
                    sql: "SELECT id FROM meetings WHERE vaultId = ?",
                    arguments: [vaultId]
                )),
                summaries: Set(UUID.fetchAll(
                    db,
                    sql: """
                    SELECT summaries.meetingId FROM summaries
                    JOIN meetings ON meetings.id = summaries.meetingId
                    WHERE meetings.vaultId = ?
                    """,
                    arguments: [vaultId]
                )),
                transcripts: Set(UUID.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT transcript_segments.meetingId FROM transcript_segments
                    JOIN meetings ON meetings.id = transcript_segments.meetingId
                    WHERE meetings.vaultId = ?
                    """,
                    arguments: [vaultId]
                )),
                screenshots: Set(UUID.fetchAll(
                    db,
                    sql: """
                    SELECT meeting_files.id FROM meeting_files
                    JOIN meetings ON meetings.id = meeting_files.meetingId
                    WHERE meetings.vaultId = ?
                    """,
                    arguments: [vaultId]
                )),
                files: Set(UUID.fetchAll(db, sql: "SELECT id FROM files WHERE vaultId = ?", arguments: [vaultId])),
                recordings: Set(UUID.fetchAll(
                    db,
                    sql: "SELECT sessionId FROM recording_archives WHERE vaultId = ? AND state = 'remote'",
                    arguments: [vaultId]
                ))
            )
        }
        let deletedProjects = existing.projects.filter { !snapshot.projects.contains($0.id) }
            .sorted { ($0.parentProjectId == nil ? 1 : 0) < ($1.parentProjectId == nil ? 1 : 0) }
            .map(\.id)
        let deletedMeetings = existing.meetings.subtracting(snapshot.meetings)
        let deletions: [(sql: String, vaultScoped: Bool, ids: [UUID])] = [
            ("DELETE FROM recording_archives WHERE sessionId = ? AND vaultId = ?", true, Array(existing.recordings.subtracting(snapshot.recordings))),
            (
                "DELETE FROM meeting_files WHERE id = ?",
                false,
                Array(existing.screenshots.subtracting(snapshot.screenshots))
            ),
            ("DELETE FROM files WHERE id = ? AND vaultId = ?", true, Array(existing.files.subtracting(snapshot.files))),
            (
                "DELETE FROM transcript_segments WHERE meetingId = ?",
                false,
                Array(existing.transcripts.subtracting(snapshot.transcripts))
            ),
            (
                "DELETE FROM summaries WHERE meetingId = ?",
                false,
                Array(existing.summaries.subtracting(snapshot.summaries))
            ),
            (
                "DELETE FROM meetings WHERE id = ? AND vaultId = ?",
                true,
                Array(deletedMeetings)
            ),
            ("DELETE FROM projects WHERE id = ? AND vaultId = ?", true, deletedProjects),
        ]
        for deletion in deletions {
            let ids = deletion.ids
            for batchStart in stride(from: 0, to: ids.count, by: 100) {
                let batch = ids[batchStart ..< min(batchStart + 100, ids.count)]
                let applyBatch = {
                    try await withCurrentAssociation(
                        vaultId: vaultId,
                        expectedConnectionId: expectedConnectionId,
                        dbQueue: dbQueue,
                        expectedMutationGeneration: expectedMutationGeneration
                    ) { db in
                        guard try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db),
                              try !hasActiveRecording(in: db)
                        else { return false }
                        for id in batch {
                            let arguments: StatementArguments = deletion.vaultScoped ? [id, vaultId] : [id]
                            try db.execute(sql: deletion.sql, arguments: arguments)
                        }
                        return true
                    }
                }
                let completed = if deletion.vaultScoped, deletion.sql.hasPrefix("DELETE FROM meetings") {
                    try await withStagedAudioDeletion(
                        meetingIds: Set(batch),
                        vaultId: vaultId,
                        expectedConnectionId: expectedConnectionId,
                        dbQueue: dbQueue,
                        expectedMutationGeneration: expectedMutationGeneration,
                        applyBatch
                    )
                } else {
                    try await applyBatch()
                }
                guard completed else { return false }
            }
        }
        return try await withCurrentAssociation(
            vaultId: vaultId,
            expectedConnectionId: expectedConnectionId,
            dbQueue: dbQueue,
            expectedMutationGeneration: expectedMutationGeneration
        ) { db in
            guard try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db),
                  try !hasActiveRecording(in: db)
            else { return false }
            try db.execute(
                sql: "DELETE FROM sync_entity_state WHERE vaultId = ? AND confirmedRevision IS NULL",
                arguments: [vaultId]
            )
            if let cursor {
                try db.execute(sql: "UPDATE vaults SET syncPullCursor = ?, syncRecoveryState = NULL WHERE id = ?", arguments: [cursor, vaultId])
            }
            return true
        }
    }

    static func advancePullCursor(
        _ cursor: String,
        vaultId: UUID,
        expectedConnectionId: UUID,
        dbQueue: DatabaseQueue,
        expectedMutationGeneration: Int64? = nil
    ) async throws -> Bool {
        try await withCurrentAssociation(
            vaultId: vaultId,
            expectedConnectionId: expectedConnectionId,
            dbQueue: dbQueue,
            expectedMutationGeneration: expectedMutationGeneration
        ) { db in
            guard try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db) else { return false }
            try db.execute(sql: "UPDATE vaults SET syncPullCursor = ? WHERE id = ?", arguments: [cursor, vaultId])
            return true
        }
    }

    private static func forgetRemoteVault(vaultId: UUID, in db: Database) throws {
        try SyncTransactionQueue.discard(vaultId: vaultId, in: db)
        try db.execute(sql: "DELETE FROM sync_entity_state WHERE vaultId = ?", arguments: [vaultId])
        try db.execute(
            sql: """
            UPDATE vaults SET syncConfirmedConnectionId = NULL,
                syncPullCursor = NULL, syncLastCommittedCursor = NULL
            WHERE id = ?
            """,
            arguments: [vaultId]
        )
    }

    static func reconcileMissingVault(
        vaultId: UUID,
        expectedConnectionId: UUID,
        dbQueue: DatabaseQueue,
        expectedMutationGeneration: Int64? = nil
    ) async throws -> Bool {
        let ownerReset = try await withCurrentAssociation(
            vaultId: vaultId, expectedConnectionId: expectedConnectionId, dbQueue: dbQueue,
            expectedMutationGeneration: expectedMutationGeneration
        ) { db in
            guard try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db),
                  try !hasActiveRecording(in: db),
                  try VaultRecord.fetchOne(db, key: vaultId)?.allowsCanonicalEdits == true else { return false }
            // Expired reset history has the same owner recovery semantics as a retained reset event.
            try forgetRemoteVault(vaultId: vaultId, in: db)
            return true
        }
        if ownerReset { return true }
        return try await removeRevokedMemberVault(
            vaultId: vaultId, expectedConnectionId: expectedConnectionId, dbQueue: dbQueue,
            expectedMutationGeneration: expectedMutationGeneration
        )
    }

    static func removeRevokedMemberVault(
        vaultId: UUID,
        expectedConnectionId: UUID,
        dbQueue: DatabaseQueue,
        expectedMutationGeneration: Int64? = nil
    ) async throws -> Bool {
        let meetingIds: Set<UUID>? = try await dbQueue.read { db in
            guard try SyncTransactionQueue.matchesExpectedConnection(vaultId: vaultId, connectionId: expectedConnectionId, in: db),
                  try VaultRecord.fetchOne(db, key: vaultId)?.syncRole == "member" else { return nil }
            return try Set(UUID.fetchAll(db, sql: "SELECT id FROM meetings WHERE vaultId = ?", arguments: [vaultId]))
        }
        guard let meetingIds else { return false }
        return try await withStagedAudioDeletion(
            meetingIds: meetingIds,
            vaultId: vaultId,
            expectedConnectionId: expectedConnectionId,
            dbQueue: dbQueue,
            expectedMutationGeneration: expectedMutationGeneration
        ) {
            try await withCurrentAssociation(
                vaultId: vaultId,
                expectedConnectionId: expectedConnectionId,
                dbQueue: dbQueue,
                expectedMutationGeneration: expectedMutationGeneration
            ) { db in
                guard try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db),
                      try !hasActiveRecording(in: db)
                else { return false }
                try db.execute(
                    sql: "DELETE FROM vaults WHERE id = ? AND syncRole = 'member'",
                    arguments: [vaultId]
                )
                return db.changesCount > 0
            }
        }
    }

    private static func delete(_ entity: SyncEntity, id: UUID, vaultId: UUID, in db: Database) throws {
        switch entity {
        case .project:
            try db.execute(sql: "DELETE FROM projects WHERE id = ? AND vaultId = ?", arguments: [id, vaultId])
        case .meeting:
            try db.execute(sql: "DELETE FROM meetings WHERE id = ? AND vaultId = ?", arguments: [id, vaultId])
        case .summary:
            try db.execute(sql: "DELETE FROM summaries WHERE meetingId = ?", arguments: [id])
        case .transcript:
            try db.execute(sql: "DELETE FROM transcript_segments WHERE meetingId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM transcripts WHERE meetingId = ?", arguments: [id])
        case .file:
            try db.execute(sql: "DELETE FROM files WHERE id = ? AND vaultId = ?", arguments: [id, vaultId])
        case .recording:
            try db.execute(sql: "DELETE FROM recording_archives WHERE sessionId = ? AND vaultId = ?", arguments: [id, vaultId])
        case .meetingFile:
            try db.execute(sql: "DELETE FROM meeting_files WHERE id = ?", arguments: [id])
        case .vault, .meetingEvent:
            break
        }
    }

    private static func upsert(
        _ change: SyncChangePage.Change,
        record: SyncCanonicalPayload,
        screenshots _: [UUID: Data],
        transcripts: [UUID: [SyncTranscriptPage.Segment]],
        vaultId: UUID,
        in db: Database
    ) throws {
        switch change.entity {
        case .meetingEvent:
            break
        case .vault, .project, .meeting, .summary, .file, .recording:
            try SyncTransactionQueue.applyCanonical(
                change.entity,
                id: change.entityId,
                vaultId: vaultId,
                value: record,
                remoteRevision: change.revision,
                in: db
            )
        case .transcript:
            if try TextContentStore.observe(entity: .transcript, id: change.entityId, vaultId: vaultId, value: record, in: db) { return }
            try applyTranscript(
                meetingId: change.entityId,
                segments: transcripts[change.entityId, default: []],
                in: db
            )
        case .meetingFile:
            try MeetingFileRecord.applyCanonical(id: change.entityId, vaultId: vaultId, value: record, in: db)
            try db.execute(
                sql: "DELETE FROM search_index_jobs WHERE indexKind = 'fts' AND targetKind = 'screenshotAnalysis' AND targetKey = ?",
                arguments: [change.entityId]
            )
            let generation = try Int.fetchOne(
                db,
                sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'"
            ) ?? 1
            try indexScreenshotDocument(id: change.entityId, generation: generation, in: db)
        }
    }

    static func applyTranscript(
        meetingId: UUID,
        segments: [SyncTranscriptPage.Segment],
        in db: Database
    ) throws {
        let canonicalIDs = segments.map(\.segmentId)
        if canonicalIDs.isEmpty {
            try db.execute(
                sql: "DELETE FROM transcript_segments WHERE meetingId = ?",
                arguments: [meetingId]
            )
        } else {
            try db.execute(
                sql: """
                DELETE FROM transcript_segments
                WHERE meetingId = ?
                  AND id NOT IN (\(canonicalIDs.map { _ in "?" }.joined(separator: ",")))
                """,
                arguments: StatementArguments([meetingId]) + StatementArguments(canonicalIDs)
            )
        }
        try upsertTranscriptSegments(segments, meetingId: meetingId, in: db)
    }

    private static func upsertTranscriptSegments(
        _ segments: [SyncTranscriptPage.Segment],
        meetingId: UUID,
        in db: Database
    ) throws {
        for segment in segments {
            try db.execute(sql: """
            INSERT INTO transcript_segments(
                id, meetingId, startedAt, endedAt, createdAt, audioSource, speakerLabel
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                meetingId = excluded.meetingId,
                startedAt = excluded.startedAt,
                endedAt = excluded.endedAt,
                createdAt = excluded.createdAt,
                audioSource = excluded.audioSource,
                speakerLabel = excluded.speakerLabel
            """, arguments: [
                segment.segmentId, meetingId, segment.startedAt, segment.endedAt,
                segment.createdAt, segment.audioSource, segment.speakerLabel,
            ])
            try TranscriptSegmentBodyRecord(segmentId: segment.segmentId, text: segment.text).save(db)
        }
    }
}
