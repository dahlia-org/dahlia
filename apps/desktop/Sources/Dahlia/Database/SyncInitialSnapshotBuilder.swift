import Foundation
import GRDB

enum SyncInitialSnapshotBuilder {
    private static let projectBatchSize = 100
    private static let transcriptBatchSize = 500

    static func enqueuePending(
        dbQueue: DatabaseQueue,
        screenshotContent: ScreenshotContentProvider = .shared,
        onFailure: @Sendable (any Error) throws -> Void = { throw $0 }
    ) async throws {
        let interruptedVaultId = try await dbQueue.read { db in
            try UUID.fetchOne(
                db,
                sql: """
                SELECT id FROM vaults
                WHERE accountConnectionId IS NOT NULL
                  AND syncConfirmedConnectionId = accountConnectionId
                  AND (syncRole IS NULL OR syncRole = 'owner')
                  AND NOT EXISTS (
                    SELECT 1 FROM sync_transactions t WHERE t.vaultId = vaults.id
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM sync_entity_state s
                    WHERE s.vaultId = vaults.id AND s.entity = 'vault' AND s.entityId = vaults.id
                  )
                ORDER BY createdAt, id
                LIMIT 1
                """
            )
        }
        if let interruptedVaultId {
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE vaults SET syncConfirmedConnectionId = NULL,
                        syncPullCursor = NULL, syncLastCommittedCursor = NULL
                    WHERE id = ?
                      AND accountConnectionId IS NOT NULL
                      AND syncConfirmedConnectionId = accountConnectionId
                      AND (syncRole IS NULL OR syncRole = 'owner')
                      AND NOT EXISTS (
                        SELECT 1 FROM sync_transactions t WHERE t.vaultId = vaults.id
                      )
                      AND NOT EXISTS (
                        SELECT 1 FROM sync_entity_state s
                        WHERE s.vaultId = vaults.id AND s.entity = 'vault' AND s.entityId = vaults.id
                      )
                    """,
                    arguments: [interruptedVaultId]
                )
            }
        }

        let pending = try await dbQueue.read { db -> [(UUID, UUID, Bool)] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT v.id, v.accountConnectionId, EXISTS (
                    SELECT 1 FROM sync_transactions t
                    JOIN sync_operations o ON o.transactionId = t.id
                    WHERE t.vaultId = v.id AND o.entity = 'vault' AND o.action = 'reset'
                ) AS restoring
                FROM vaults v
                WHERE v.accountConnectionId IS NOT NULL
                  AND v.syncConfirmedConnectionId IS NULL
                  AND (v.syncRole IS NULL OR v.syncRole = 'owner')
                  AND (
                    EXISTS (
                      SELECT 1 FROM sync_transactions t
                      JOIN sync_operations o ON o.transactionId = t.id
                      WHERE t.vaultId = v.id AND o.entity = 'vault' AND o.action = 'reset'
                    )
                    OR NOT EXISTS (
                      SELECT 1 FROM sync_entity_state s
                      WHERE s.vaultId = v.id AND s.entity = 'vault' AND s.entityId = v.id
                    )
                  )
                ORDER BY v.createdAt, v.id
                """
            ).map { ($0["id"], $0["accountConnectionId"], $0["restoring"]) }
        }
        for (vaultId, connectionId, restoring) in pending {
            do {
                try await enqueue(
                    vaultId: vaultId, connectionId: connectionId, restoring: restoring,
                    dbQueue: dbQueue, screenshotContent: screenshotContent
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Background synchronization can report this Vault's failure and continue other Vaults.
                // Explicit recovery callers keep the default throwing behavior.
                try onFailure(error)
            }
        }
    }

    private static func enqueue(
        vaultId: UUID,
        connectionId: UUID,
        restoring: Bool,
        dbQueue: DatabaseQueue,
        screenshotContent: ScreenshotContentProvider
    ) async throws {
        try await screenshotContent.hydrateOriginals(vaultId: vaultId, dbQueue: dbQueue)
        guard let markerId = try await dbQueue.write({ db -> UUID? in
            guard try !hasActiveRecording(in: db),
                  let vault = try VaultRecord.fetchOne(db, key: vaultId),
                  vault.accountConnectionId == connectionId,
                  vault.syncConfirmedConnectionId == nil else { return nil }
            try SyncTransactionQueue.discard(vaultId: vaultId, in: db)
            if restoring {
                try SyncTransactionRecorder.record(
                    vaultId: vaultId,
                    operations: [restoreResetOperation(vaultId: vaultId)],
                    allowAfterReset: true,
                    connectionIdOverride: connectionId,
                    in: db
                )
            }
            return try SyncTransactionRecorder.record(
                vaultId: vaultId,
                operations: [operation(
                    entity: .vault,
                    action: .create,
                    id: vault.id,
                    payload: ["name": vault.name, "createdAt": vault.createdAt.ISO8601Format()]
                )],
                allowAfterReset: restoring,
                connectionIdOverride: connectionId,
                in: db
            )
        }) else { return }

        try await enqueueProjects(
            vaultId: vaultId,
            connectionId: connectionId,
            markerId: markerId,
            restoring: restoring,
            dbQueue: dbQueue
        )
        try await enqueueMeetings(
            vaultId: vaultId,
            connectionId: connectionId,
            markerId: markerId,
            restoring: restoring,
            dbQueue: dbQueue
        )

        _ = try await dbQueue.write { db in
            guard try canContinue(markerId: markerId, vaultId: vaultId, in: db) else { return false }
            if restoring {
                try db.execute(sql: "DELETE FROM sync_entity_state WHERE vaultId = ?", arguments: [vaultId])
            }
            try db.execute(
                sql: """
                UPDATE vaults SET syncConfirmedConnectionId = accountConnectionId
                WHERE id = ? AND accountConnectionId = ? AND syncConfirmedConnectionId IS NULL
                """,
                arguments: [vaultId, connectionId]
            )
            return db.changesCount == 1
        }
    }

    private static func enqueueProjects(
        vaultId: UUID,
        connectionId: UUID,
        markerId: UUID,
        restoring: Bool,
        dbQueue: DatabaseQueue
    ) async throws {
        for roots in [true, false] {
            var lastId: UUID?
            while true {
                try Task.checkCancellation()
                let cursor = lastId
                let projects = try await dbQueue.write { db -> [ProjectRecord] in
                    guard try canContinue(markerId: markerId, vaultId: vaultId, in: db) else { return [] }
                    let parentClause = roots ? "parentProjectId IS NULL" : "parentProjectId IS NOT NULL"
                    let cursorClause = cursor == nil ? "" : "AND id > ?"
                    var arguments: StatementArguments = [vaultId]
                    if let cursor { arguments += [cursor] }
                    let projects = try ProjectRecord.fetchAll(
                        db,
                        sql: """
                        SELECT * FROM projects
                        WHERE vaultId = ? AND \(parentClause) \(cursorClause)
                        ORDER BY id LIMIT \(projectBatchSize)
                        """,
                        arguments: arguments
                    )
                    try SyncTransactionRecorder.recordBatches(
                        vaultId: vaultId,
                        operations: projects.map { try projectOperation($0, action: .create) },
                        allowAfterReset: restoring,
                        connectionIdOverride: connectionId,
                        in: db
                    )
                    return projects
                }
                guard let nextId = projects.last?.id else { break }
                lastId = nextId
            }
        }
    }

    private static func enqueueMeetings(
        vaultId: UUID,
        connectionId: UUID,
        markerId: UUID,
        restoring: Bool,
        dbQueue: DatabaseQueue
    ) async throws {
        var lastMeetingId: UUID?
        while true {
            try Task.checkCancellation()
            let cursor = lastMeetingId
            let meeting = try await dbQueue.write { db -> MeetingRecord? in
                guard try canContinue(markerId: markerId, vaultId: vaultId, in: db) else { return nil }
                let meeting = if let cursor {
                    try MeetingRecord.fetchOne(
                        db,
                        sql: "SELECT * FROM meetings WHERE vaultId = ? AND id > ? ORDER BY id LIMIT 1",
                        arguments: [vaultId, cursor]
                    )
                } else {
                    try MeetingRecord.fetchOne(
                        db,
                        sql: "SELECT * FROM meetings WHERE vaultId = ? ORDER BY id LIMIT 1",
                        arguments: [vaultId]
                    )
                }
                guard let meeting else { return nil }
                var metadata = try [meetingOperation(meeting, action: .create)]
                if let summary = try SummaryRecord.fetchOne(db, key: meeting.id) {
                    try metadata.append(summaryOperation(summary, action: .upsert))
                }
                try SyncTransactionRecorder.record(
                    vaultId: vaultId,
                    operations: metadata,
                    allowAfterReset: restoring,
                    connectionIdOverride: connectionId,
                    in: db
                )
                return meeting
            }
            guard let meeting else { break }
            lastMeetingId = meeting.id

            try await enqueueTranscript(
                meetingId: meeting.id,
                vaultId: vaultId,
                connectionId: connectionId,
                markerId: markerId,
                restoring: restoring,
                dbQueue: dbQueue
            )
            try await enqueueScreenshots(
                meetingId: meeting.id,
                vaultId: vaultId,
                connectionId: connectionId,
                markerId: markerId,
                restoring: restoring,
                dbQueue: dbQueue
            )
        }
    }

    private static func enqueueTranscript(
        meetingId: UUID,
        vaultId: UUID,
        connectionId: UUID,
        markerId: UUID,
        restoring: Bool,
        dbQueue: DatabaseQueue
    ) async throws {
        var lastSegmentId: UUID?
        while true {
            let cursor = lastSegmentId
            let segments = try await dbQueue.write { db -> [TranscriptSegmentRecord] in
                guard try canContinue(markerId: markerId, vaultId: vaultId, in: db) else { return [] }
                let segments = if let cursor {
                    try TranscriptSegmentRecord.fetchAll(
                        db,
                        sql: """
                        SELECT * FROM transcript_segments
                        WHERE meetingId = ? AND isConfirmed = 1 AND id > ?
                        ORDER BY id LIMIT \(transcriptBatchSize)
                        """,
                        arguments: [meetingId, cursor]
                    )
                } else {
                    try TranscriptSegmentRecord.fetchAll(
                        db,
                        sql: """
                        SELECT * FROM transcript_segments
                        WHERE meetingId = ? AND isConfirmed = 1
                        ORDER BY id LIMIT \(transcriptBatchSize)
                        """,
                        arguments: [meetingId]
                    )
                }
                guard !segments.isEmpty else { return [] }
                let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: meetingId)
                try SyncTransactionRecorder.record(
                    vaultId: vaultId,
                    operations: [patch],
                    transcriptSegments: [patch.id: segments.map(SyncTranscriptPatchSegment.init)],
                    allowAfterReset: restoring,
                    connectionIdOverride: connectionId,
                    in: db
                )
                return segments
            }
            guard let nextId = segments.last?.id else { break }
            lastSegmentId = nextId
        }
    }

    private static func enqueueScreenshots(
        meetingId: UUID,
        vaultId: UUID,
        connectionId: UUID,
        markerId: UUID,
        restoring: Bool,
        dbQueue: DatabaseQueue
    ) async throws {
        var lastScreenshotId: UUID?
        while true {
            let cursor = lastScreenshotId
            let screenshot = try await dbQueue.write { db -> MeetingScreenshotRecord? in
                guard try canContinue(markerId: markerId, vaultId: vaultId, in: db) else { return nil }
                let screenshot = if let cursor {
                    try MeetingScreenshotRecord.fetchOne(
                        db,
                        sql: "SELECT * FROM screenshots WHERE meetingId = ? AND id > ? ORDER BY id LIMIT 1",
                        arguments: [meetingId, cursor]
                    )
                } else {
                    try MeetingScreenshotRecord.fetchOne(
                        db,
                        sql: "SELECT * FROM screenshots WHERE meetingId = ? ORDER BY id LIMIT 1",
                        arguments: [meetingId]
                    )
                }
                guard let screenshot else { return nil }
                let bytes = try screenshot.requiredOriginal()
                let attachment = SyncScreenshotAttachment(mimeType: screenshot.mimeType, bytes: bytes)
                let operation = try screenshotOperation(screenshot, action: .upsert, contentHash: attachment.sha256)
                try SyncTransactionRecorder.record(
                    vaultId: vaultId,
                    operations: [operation],
                    screenshotAttachments: [operation.id: attachment],
                    allowAfterReset: restoring,
                    connectionIdOverride: connectionId,
                    in: db
                )
                return screenshot
            }
            guard let screenshot else { break }
            lastScreenshotId = screenshot.id
        }
    }

    static func prepareRestore(dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { db in
            let vaultIds = try UUID.fetchAll(
                db,
                sql: """
                SELECT id FROM vaults
                WHERE syncConfirmedConnectionId IS NOT NULL
                  AND (syncRole IS NULL OR syncRole = 'owner')
                """
            )
            for vaultId in vaultIds {
                try SyncTransactionQueue.discard(vaultId: vaultId, in: db)
                try SyncTransactionRecorder.record(
                    vaultId: vaultId,
                    operations: [restoreResetOperation(vaultId: vaultId)],
                    in: db
                )
                try db.execute(
                    sql: """
                    UPDATE vaults SET syncConfirmedConnectionId = NULL,
                        syncPullCursor = NULL, syncLastCommittedCursor = NULL
                    WHERE id = ?
                    """,
                    arguments: [vaultId]
                )
            }
        }
    }

    private static func canContinue(markerId: UUID, vaultId: UUID, in db: Database) throws -> Bool {
        let markerExists = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sync_transactions WHERE id = ? AND vaultId = ?)",
            arguments: [markerId, vaultId]
        ) ?? false
        guard markerExists else { return false }
        if try hasActiveRecording(in: db) {
            try SyncTransactionQueue.discardPartialSnapshot(vaultId: vaultId, in: db)
            return false
        }
        return true
    }

    private static func hasActiveRecording(in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM recording_sessions WHERE endedAt IS NULL)"
        ) ?? false
    }

    private static func restoreResetOperation(vaultId: UUID) throws -> SyncOperationDraft {
        try SyncOperationDraft(
            entity: .vault,
            action: .reset,
            entityId: vaultId,
            payloadJSON: SyncJSON.encoder.encode(["preservePermissions": true])
        )
    }

    static func meetingOperation(_ meeting: MeetingRecord, action: SyncAction) throws -> SyncOperationDraft {
        var payload: [String: Any] = [
            "projectId": json(meeting.projectId),
            "name": meeting.name,
            "description": meeting.description,
            "status": meeting.status.rawValue,
            "duration": json(meeting.duration),
            "recordingStartedAt": json(meeting.recordingStartedAt),
            "updatedAt": meeting.updatedAt.ISO8601Format(),
        ]
        if action == .create { payload["createdAt"] = meeting.createdAt.ISO8601Format() }
        return try operation(entity: .meeting, action: action, id: meeting.id, payload: payload)
    }

    static func summaryOperation(_ summary: SummaryRecord, action: SyncAction) throws -> SyncOperationDraft {
        try operation(
            entity: .summary,
            action: action,
            id: summary.meetingId,
            payload: action == .delete ? [:] : [
                "title": summary.title,
                "document": summary.document,
                "createdAt": summary.createdAt.ISO8601Format(),
            ]
        )
    }

    static func screenshotOperation(
        _ screenshot: MeetingScreenshotRecord,
        action: SyncAction,
        contentHash: String? = nil
    ) throws -> SyncOperationDraft {
        try operation(
            entity: .screenshot,
            action: action,
            id: screenshot.id,
            payload: [
                "meetingId": screenshot.meetingId.uuidString.lowercased(),
                "capturedAt": screenshot.capturedAt.ISO8601Format(),
                "ocrText": json(screenshot.ocrText),
                "caption": json(screenshot.caption),
                "contentHash": json(contentHash),
            ]
        )
    }

    static func projectOperation(_ project: ProjectRecord, action: SyncAction) throws -> SyncOperationDraft {
        guard project.description.utf16.count <= 20000 else {
            throw ProjectWorkspaceError.descriptionTooLong
        }
        var payload: [String: Any] = [
            "parentProjectId": json(project.parentProjectId),
            "name": project.name,
            "description": project.description,
            "projectType": json(project.projectType?.rawValue),
        ]
        if action == .create { payload["createdAt"] = project.createdAt.ISO8601Format() }
        return try operation(entity: .project, action: action, id: project.id, payload: payload)
    }

    static func vaultOperation(_ vault: VaultRecord, action: SyncAction) throws -> SyncOperationDraft {
        var payload: [String: Any] = ["name": vault.name]
        if action == .create { payload["createdAt"] = vault.createdAt.ISO8601Format() }
        return try operation(entity: .vault, action: action, id: vault.id, payload: payload)
    }

    private static func operation(
        entity: SyncEntity,
        action: SyncAction,
        id: UUID,
        payload: [String: Any]
    ) throws -> SyncOperationDraft {
        try SyncOperationDraft(
            entity: entity,
            action: action,
            entityId: id,
            payloadJSON: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        )
    }

    private static func json(_ value: UUID?) -> Any { value?.uuidString.lowercased() ?? NSNull() }
    private static func json(_ value: Date?) -> Any { value?.ISO8601Format() ?? NSNull() }
    private static func json(_ value: String?) -> Any { value ?? NSNull() }
    private static func json(_ value: Double?) -> Any { value ?? NSNull() }
}
