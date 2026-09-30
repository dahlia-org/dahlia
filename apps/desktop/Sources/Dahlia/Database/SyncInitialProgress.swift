import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

/// Construction metadata is committed with each entity's immutable outbound operation.
enum SyncInitialProgress {
    static func active(workspaceId: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_initial_builds WHERE workspaceId = ?)", arguments: [workspaceId]) == true
    }

    static func built(_ entity: SyncEntity, id: UUID, workspaceId: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT built FROM sync_initial_entities WHERE workspaceId = ? AND entity = ? AND entityId = ?",
            arguments: [workspaceId, entity, id]
        ) == true
    }

    static func mark(_ operations: [SyncOperationDraft], workspaceId: UUID, in db: Database) throws {
        guard try active(workspaceId: workspaceId, in: db) else { return }
        for operation in operations {
            let wasBuilt = try built(operation.entity, id: operation.entityId, workspaceId: workspaceId, in: db)
            if !wasBuilt {
                try db.execute(sql: """
                INSERT OR IGNORE INTO local_workspace_import_operations(operationId, importId)
                SELECT ?, importId FROM sync_initial_builds WHERE workspaceId = ? AND importId IS NOT NULL
                """, arguments: [operation.id, workspaceId])
            }
            try db.execute(sql: """
            INSERT INTO sync_initial_entities(workspaceId, entity, entityId, resource, built) VALUES (?, ?, ?, ?, 1)
            ON CONFLICT(workspaceId, entity, entityId) DO UPDATE SET built = 1
            """, arguments: [
                workspaceId,
                operation.entity,
                operation.entityId,
                "exists:\(SyncDependencies.key(operation.entity, operation.entityId))",
            ])
        }

    }

    /// A first edit can initialize its entity directly. Already-built entities retain the original operation.
    /// The complete transaction remains atomic; only never-published deletions have no remote effect.
    static func prepare(_ operations: [SyncOperationDraft], workspaceId: UUID, in db: Database) throws -> [SyncOperationDraft] {
        guard try active(workspaceId: workspaceId, in: db) else { return operations }
        var result: [SyncOperationDraft] = []
        for operation in operations {
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sync_initial_entities WHERE workspaceId = ? AND entity = ? AND entityId = ? AND built = 0)",
                arguments: [workspaceId, operation.entity, operation.entityId]
            ) == true else {
                result.append(operation)
                continue
            }
            if operation.action == .delete {
                try db.execute(
                    sql: "DELETE FROM sync_initial_entities WHERE workspaceId = ? AND entity = ? AND entityId = ?",
                    arguments: [workspaceId, operation.entity, operation.entityId]
                )
                // Keep a deletion when another queued operation already references this entity.
                // Its initial create must run first so those immutable requests remain valid.
                let referenced = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM sync_dependency_keys WHERE resource = ?)",
                    arguments: ["exists:\(SyncDependencies.key(operation.entity, operation.entityId))"]
                ) == true
                if referenced { throw TextContentError.changed }
                continue
            }
            if operation.entity == .transcript,
               try RecordingSessionRecord.hasActiveRecording(workspaceId: workspaceId, in: db) {
                // Finalized segments remain in the canonical local tables. Construct one
                // complete confirmed snapshot after recording stops, without replacing a
                // live transcript or publishing its interim segments.
                continue
            }
            let initial: SyncOperationDraft
            switch operation.entity {
            case .project:
                guard let row = try ProjectRecord.fetchOne(db, key: operation.entityId) else { result.append(operation)
                    continue
                }
                initial = try SyncInitialSnapshotBuilder.projectOperation(row, action: .create)
            case .meeting:
                guard let row = try MeetingRecord.fetchOne(db, key: operation.entityId) else { result.append(operation)
                    continue
                }
                initial = try SyncInitialSnapshotBuilder.meetingOperation(row, action: .create, in: db)
            case .transcript:
                if let info = try TranscriptRecord.current(operation.entityId, in: db) {
                    initial = try TranscriptRecord.mutation(meetingId: operation.entityId, info: info, mode: "replace")
                } else { initial = operation }
            default: initial = operation
            }
            result.append(.init(
                id: operation.id,
                entity: initial.entity,
                action: initial.action,
                entityId: initial.entityId,
                payloadJSON: initial.payloadJSON
            ))
        }
        return result
    }

    static func initialTranscriptOperations(
        _ requestedOperations: [SyncOperationDraft],
        workspaceId: UUID,
        buildingInitial: Bool,
        in db: Database
    ) throws -> Set<UUID> {
        try Set(requestedOperations.filter { operation in
            guard !buildingInitial, operation.entity == .transcript,
                  operation.payloadJSON.flatMap({ try? SyncJSON.decoder.decode(TranscriptMutation.self, from: $0).mode }) != "replace"
            else { return false }
            return try Self.active(workspaceId: workspaceId, in: db)
                && !Self.built(.transcript, id: operation.entityId, workspaceId: workspaceId, in: db)
        }.map(\.id))
    }

    static func register(
        workspaceId: UUID,
        items: [WorkspaceRelocation.Item]? = nil,
        existing: SyncResetSnapshot = .init(ids: [:]),
        in db: Database
    ) throws {
        for (entity, table, idColumn, predicate, exclude) in [
            (SyncEntity.project, "projects", "id", "workspace_id = ?", existing.projects),
            (.meeting, "meetings", "id", "workspace_id = ?", existing.meetings),
            (.summary, "summaries", "meetingId", "meetingId IN (SELECT id FROM meetings WHERE workspace_id = ?)", existing.summaries),
            (
                .transcript,
                "(SELECT meetingId FROM transcripts UNION SELECT meetingId FROM transcript_segments)",
                "meetingId",
                "meetingId IN (SELECT id FROM meetings WHERE workspace_id = ?)",
                existing.transcripts
            ),
            (.file, "files", "id", "workspace_id = ?", existing.files),
            (.meetingAttachment, "meeting_attachments", "id", "meetingId IN (SELECT id FROM meetings WHERE workspace_id = ?)", existing.screenshots),
        ] {
            let selected: Set<UUID>? = items
                .map {
                    Set($0
                        .filter {
                            $0
                                .entity == entity ||
                                ((entity == .summary || entity == .transcript || entity == .meetingAttachment) && $0.entity == .meeting)
                        }
                        .map(\.id))
                }
            let excludedJSON = try String(decoding: JSONEncoder().encode(exclude.map { $0.uuidString.lowercased() }), as: UTF8.self)
            let selectedJSON = try selected.map { try String(decoding: JSONEncoder().encode($0.map { $0.uuidString.lowercased() }), as: UTF8.self) }
            func uuidText(_ column: String) -> String {
                let hex = "lower(hex(\(column)))"
                return "CASE WHEN typeof(\(column)) = 'blob' THEN substr(\(hex),1,8)||'-'||substr(\(hex),9,4)||'-'||substr(\(hex),13,4)||'-'||substr(\(hex),17,4)||'-'||substr(\(hex),21,12) ELSE lower(\(column)) END"
            }
            // Only compact identity metadata is registered here. Bodies are constructed in
            // subsequent short transactions; avoid thousands of Swift-to-SQL round trips.
            let parentColumn = entity == .meetingAttachment ? "meetingId" : idColumn
            try db.execute(sql: """
            INSERT OR IGNORE INTO sync_initial_entities(workspaceId, entity, entityId, resource)
            SELECT ?, ?, \(idColumn), ? || (\(uuidText(idColumn))) FROM \(table)
            WHERE \(predicate) AND (\(uuidText(idColumn))) NOT IN (SELECT value FROM json_each(?))
              AND (? IS NULL OR (\(uuidText(parentColumn))) IN (SELECT value FROM json_each(?)))
            """, arguments: [workspaceId, entity, "exists:\(entity.rawValue):", workspaceId, excludedJSON, selectedJSON, selectedJSON])

        }
    }
}

extension SyncInitialProgress {
    static func start(
        workspaceId: UUID,
        connectionId: UUID,
        restoring: Bool,
        replaceImages: Bool,
        importId: UUID? = nil,
        items: [WorkspaceRelocation.Item]? = nil,
        existing: SyncResetSnapshot = .init(ids: [:]),
        in db: Database
    ) throws {
        if try active(workspaceId: workspaceId, in: db) { return }
        if try WorkspaceRecord.fetchOne(db, key: workspaceId)?.syncConfirmedConnectionId == nil {
            guard try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM sync_transactions WHERE workspace_id = ? AND (attempts > 0 OR leaseExpiresAt IS NOT NULL)",
                arguments: [workspaceId]
            ) == 0 else { throw TextContentError.changed }
            try SyncTransactionQueue.discardPartialSnapshot(workspaceId: workspaceId, in: db)
        }
        try db.execute(
            sql: "INSERT INTO sync_initial_builds(id, workspaceId, connectionId, restoring, replaceImages, importId) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [UUID.v7(), workspaceId, connectionId, restoring, replaceImages, importId]
        )
        try register(workspaceId: workspaceId, items: items, existing: existing, in: db)
        guard let workspace = try WorkspaceRecord.fetchOne(db, key: workspaceId) else { throw TextContentError.changed }
        let needsWorkspace = try importId == nil && (workspace.syncConfirmedConnectionId == nil || !Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sync_entity_state WHERE workspace_id = ? AND entity = 'workspace')",
            arguments: [workspaceId]
        )!)
        if restoring {
            // The reset already captured its immutable base revision; rebuilt entities start afresh.
            try db.execute(sql: "DELETE FROM sync_entity_state WHERE workspace_id = ?", arguments: [workspaceId])
            try db.execute(sql: "DELETE FROM sync_confirmed_relations WHERE workspaceId = ?", arguments: [workspaceId])
        }
        if needsWorkspace {
            try SyncTransactionRecorder.record(
                workspaceId: workspaceId,
                background: true,
                buildingInitial: true,
                operations: [SyncInitialSnapshotBuilder.workspaceOperation(workspace, action: .create)],
                allowAfterReset: restoring,
                connectionIdOverride: connectionId,
                in: db
            )
            try db.execute(sql: "UPDATE workspaces SET syncConfirmedConnectionId = ? WHERE id = ?", arguments: [connectionId, workspaceId])
        }
    }

    static func enqueuePending(
        dbQueue: DatabaseQueue,
        screenshotContent: ScreenshotContentProvider,
        replaceImages: UUID?,
        onFailure: @Sendable (any Error) throws -> Void
    ) async throws {
        let workspaces = try await dbQueue.read { db in
            try WorkspaceRecord.fetchAll(db, sql: """
            SELECT * FROM workspaces w WHERE w.accountConnectionId IS NOT NULL
              AND (w.syncRole = 'admin' OR EXISTS(SELECT 1 FROM sync_initial_builds b WHERE b.workspaceId = w.id))
              AND (? IS NULL OR w.id = ?) AND (
                EXISTS(SELECT 1 FROM sync_initial_builds b WHERE b.workspaceId = w.id)
                OR NOT EXISTS(SELECT 1 FROM sync_entity_state s WHERE s.workspace_id = w.id AND s.entity = 'workspace')
                  AND NOT EXISTS(SELECT 1 FROM sync_transactions t WHERE t.workspace_id = w.id)
                OR w.syncConfirmedConnectionId IS NULL AND EXISTS(
                  SELECT 1 FROM sync_transactions t JOIN sync_operations o ON o.transactionId = t.id
                    WHERE t.workspace_id = w.id AND o.entity = 'workspace' AND o.action = 'reset'))
            ORDER BY w.id
            """, arguments: [replaceImages, replaceImages])
        }
        var startedWorkspaces: [UUID] = []
        for workspace in workspaces {
            do {
                let started = try await dbQueue.write { db in
                    guard try !RecordingSessionRecord.hasActiveRecording(workspaceId: workspace.id, in: db),
                          let current = try WorkspaceRecord.fetchOne(db, key: workspace.id),
                          current.accountConnectionId == workspace.accountConnectionId,
                          let connection = current.accountConnectionId else { return false }
                    let restoring = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
                      WHERE t.workspace_id = ? AND o.entity = 'workspace' AND o.action = 'reset')
                    """, arguments: [workspace.id]) == true
                    try start(
                        workspaceId: workspace.id,
                        connectionId: connection,
                        restoring: restoring,
                        replaceImages: workspace.id == replaceImages,
                        in: db
                    )
                    return true
                }
                guard started else { continue }
                startedWorkspaces.append(workspace.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try onFailure(error)
            }
        }
        screenshotContent.retainOriginals(workspaceIds: startedWorkspaces, dbQueue: dbQueue)
        defer { screenshotContent.releaseOriginals(workspaceIds: startedWorkspaces, dbQueue: dbQueue) }
        var ready = startedWorkspaces
        // Commit one entity per Workspace per turn. A large import cannot postpone the
        // construction of the next Workspace's first independently sendable request.
        while !ready.isEmpty {
            var remaining: [UUID] = []
            for workspace in ready {
                try Task.checkCancellation()
                do {
                    let next = try await dbQueue.read { db in
                        try nextEntity(workspaceId: workspace, in: db).map { (entity: $0["entity"] as String, id: $0["entityId"] as UUID) }
                    }
                    if let next, next.entity == SyncEntity.file.rawValue {
                        try await screenshotContent.prepareOriginals(workspaceId: workspace, dbQueue: dbQueue, screenshotIds: [next.id])
                    }
                    if try await dbQueue.write({ try constructNext(workspaceId: workspace, in: $0) }) { remaining.append(workspace) }
                } catch { try onFailure(error) }
                await Task.yield()
            }
            ready = remaining
        }
    }

    private static func nextEntity(workspaceId: UUID, resource: String? = nil, in db: Database) throws -> Row? {
        try Row.fetchOne(db, sql: """
        SELECT p.* FROM sync_initial_entities p WHERE p.workspaceId = ? AND p.built = 0 AND (? IS NULL OR p.resource = ?)
        ORDER BY priority DESC, CASE entity WHEN 'project' THEN 0 WHEN 'meeting' THEN 1 WHEN 'summary' THEN 2 WHEN 'transcript' THEN 3 WHEN 'file' THEN 4 ELSE 5 END, entityId LIMIT 1
        """, arguments: [workspaceId, resource, resource])
    }

    static func constructNext(workspaceId: UUID, resource: String? = nil, in db: Database) throws -> Bool {
        guard let build = try Row.fetchOne(
            db,
            sql: """
            SELECT b.* FROM sync_initial_builds b JOIN workspaces w ON w.id = b.workspaceId
            WHERE b.workspaceId = ? AND w.accountConnectionId = b.connectionId AND w.syncConfirmedConnectionId = b.connectionId
            """,
            arguments: [workspaceId]
        ),
            try resource != nil || !RecordingSessionRecord.hasActiveRecording(workspaceId: workspaceId, in: db) else { return false }
        guard let next = try nextEntity(workspaceId: workspaceId, resource: resource, in: db) else {
            if resource != nil { return false }
            try db.execute(sql: "DELETE FROM sync_initial_entities WHERE workspaceId = ?", arguments: [workspaceId])
            try db.execute(sql: "DELETE FROM sync_initial_builds WHERE workspaceId = ?", arguments: [workspaceId])
            try LocalWorkspaceImportRecord.complete(in: db)
            return false
        }
        let entity: SyncEntity = next["entity"], id: UUID = next["entityId"], restoring: Bool = build["restoring"]
        var operations: [SyncOperationDraft] = []
        var attachments: [UUID: SyncScreenshotAttachmentReference] = [:]
        switch entity {
        case .project:
            if let row = try ProjectRecord.fetchOne(db, key: id), row.workspaceId == workspaceId {
                operations = try [SyncInitialSnapshotBuilder.projectOperation(row, action: .create)]
            }
        case .meeting:
            if let row = try MeetingRecord.fetchOne(db, key: id), row.workspaceId == workspaceId {
                operations = try [SyncInitialSnapshotBuilder.meetingOperation(row, action: .create, in: db)]
            }
        case .file:
            if let row = try FileRecord.fetchOne(db, key: id), row.workspaceId == workspaceId {
                guard let reference = row.localReference else { throw TextContentError.unavailable }
                let operation = try SyncInitialSnapshotBuilder.fileOperation(row, replaceServerImageAnalysis: build["replaceImages"], in: db)
                operations = [operation]
                attachments[operation.id] = try .init(
                    mimeType: row.contentType,
                    source: JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(reference.utf8))
                )
            }
        case .meetingAttachment:
            if let row = try MeetingAttachmentRecord
                .fetchOne(db, key: id) { operations = try [SyncInitialSnapshotBuilder.meetingAttachmentOperation(row)] }
        case .summary:
            if try MeetingRecord.fetchOne(db, key: id) != nil {
                try TextContentAccess.requireComplete(entity: .summary, id: id, in: db)
                if let row = try SummaryContent.fetchOne(db, key: id) { operations = try [SyncInitialSnapshotBuilder.summaryOperation(
                    row,
                    action: .upsert
                )] }
            }
        case .transcript:
            if try MeetingRecord.fetchOne(db, key: id) != nil {
                try TextContentAccess.requireComplete(entity: .transcript, id: id, in: db)
                var info = try TranscriptRecord.current(id, in: db) ?? TranscriptInfo(
                    id: .v7(),
                    status: "completed",
                    startedAt: nil,
                    completedAt: nil,
                    metadata: nil
                )
                info.version = nil
                info.syncRevision = nil
                try TranscriptRecord(meetingId: id, info: info).save(db)
                try TranscriptRecord.enqueueSnapshot(meetingId: id, info: info, allowAfterReset: restoring, buildingInitial: true, in: db)
            }
        case .workspace, .recording, .meetingEvent: break
        }
        if !operations.isEmpty {
            try SyncTransactionRecorder.record(
                workspaceId: workspaceId,
                background: true,
                buildingInitial: true,
                operations: operations,
                screenshotAttachments: attachments,
                allowAfterReset: restoring,
                in: db
            )
        }
        if next["priority"] as Int == 1 {
            try db.execute(sql: """
            UPDATE sync_transactions SET syncPriority = 1 WHERE id IN (
                SELECT transactionId FROM sync_operations WHERE entity = ? AND entityId = ?)
            """, arguments: [entity, id])
        }
        try db.execute(
            sql: "UPDATE sync_initial_entities SET built = 1 WHERE workspaceId = ? AND entity = ? AND entityId = ?",
            arguments: [workspaceId, entity, id]
        )
        return true
    }
}
