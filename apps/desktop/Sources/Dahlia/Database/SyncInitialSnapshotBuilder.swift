import Foundation
import GRDB

enum SyncInitialSnapshotBuilder {
    static func enqueuePending(in db: Database) throws {
        // Existing transactions keep draining during recording, but constructing a full initial
        // snapshot must not monopolize the same SQLite writer used by finalized transcript ingress.
        let isRecording = try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM recording_sessions WHERE endedAt IS NULL)"
        ) ?? false
        guard !isRecording else { return }

        let vaultIds = try UUID.fetchAll(
            db,
            sql: """
            SELECT v.id FROM vaults v
            WHERE v.syncEnabled = 1
              AND v.accountConnectionId IS NOT NULL
              AND (v.syncConfirmedConnectionId IS NULL
                   OR v.accountConnectionId = v.syncConfirmedConnectionId)
              AND NOT EXISTS (SELECT 1 FROM sync_transactions t WHERE t.vaultId = v.id)
              AND NOT EXISTS (
                SELECT 1 FROM sync_entity_state s
                WHERE s.vaultId = v.id AND s.entity = 'vault' AND s.entityId = v.id
              )
            ORDER BY v.createdAt, v.id
            """
        )
        for vaultId in vaultIds {
            try db.execute(
                sql: """
                UPDATE vaults SET syncConfirmedConnectionId = accountConnectionId
                WHERE id = ? AND syncConfirmedConnectionId IS NULL
                """,
                arguments: [vaultId]
            )
            try enqueue(vaultId: vaultId, in: db)
        }
    }

    static func enqueue(vaultId: UUID, allowAfterReset: Bool = false, in db: Database) throws {
        guard let vault = try VaultRecord.fetchOne(db, key: vaultId),
              vault.syncConfirmedConnectionId != nil else { return }

        try SyncTransactionRecorder.record(
            vaultId: vaultId,
            operations: [operation(
                entity: .vault,
                action: .create,
                id: vault.id,
                payload: [
                    "name": vault.name,
                    "createdAt": vault.createdAt.ISO8601Format(),
                ]
            )],
            allowAfterReset: allowAfterReset,
            in: db
        )

        let projects = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
            .sorted {
                let left = $0.path.split(separator: "/").count
                let right = $1.path.split(separator: "/").count
                return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
            }
        let projectOperations = try projects.map { project in
            try operation(
                entity: .project,
                action: .create,
                id: project.id,
                payload: [
                    "parentProjectId": json(project.parentProjectId),
                    "name": project.name,
                    "description": project.description,
                    "projectType": json(project.projectType?.rawValue),
                    "createdAt": project.createdAt.ISO8601Format(),
                ]
            )
        }
        try SyncTransactionRecorder.recordBatches(
            vaultId: vaultId,
            operations: projectOperations,
            allowAfterReset: allowAfterReset,
            in: db
        )

        let meetings = try MeetingRecord
            .filter(Column("vaultId") == vaultId)
            .order(Column("createdAt"), Column("id"))
            .fetchAll(db)
        for meeting in meetings {
            var metadata = try [meetingOperation(meeting, action: .create)]
            if let summary = try SummaryRecord.fetchOne(db, key: meeting.id) {
                try metadata.append(summaryOperation(summary, action: .upsert))
            }
            try SyncTransactionRecorder.record(
                vaultId: vaultId,
                operations: metadata,
                allowAfterReset: allowAfterReset,
                in: db
            )

            let segments = try TranscriptSegmentRecord
                .filter(Column("meetingId") == meeting.id)
                .order(Column("startTime"), Column("id"))
                .fetchAll(db)
            let transcript = SyncTranscriptPatchSnapshot(
                segments: segments.map(SyncTranscriptPatchSegment.init),
                deletions: []
            )
            for snapshot in try SyncWorker.transcriptPatches(transcript) {
                let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: meeting.id)
                try SyncTransactionRecorder.record(
                    vaultId: vaultId,
                    operations: [patch],
                    transcriptSegments: [patch.id: snapshot.segments],
                    allowAfterReset: allowAfterReset,
                    in: db
                )
            }

            let screenshots = try MeetingScreenshotRecord
                .filter(Column("meetingId") == meeting.id)
                .order(Column("capturedAt"), Column("id"))
                .fetchAll(db)
            for screenshot in screenshots {
                let attachment = SyncScreenshotAttachment(mimeType: screenshot.mimeType, bytes: screenshot.imageData)
                let operation = try screenshotOperation(screenshot, action: .upsert, contentHash: attachment.sha256)
                try SyncTransactionRecorder.record(
                    vaultId: vaultId,
                    operations: [operation],
                    screenshotAttachments: [operation.id: attachment],
                    allowAfterReset: allowAfterReset,
                    in: db
                )
            }
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
                try db.execute(sql: "DELETE FROM sync_entity_state WHERE vaultId = ?", arguments: [vaultId])
                try db.execute(
                    sql: "UPDATE vaults SET syncPullCursor = NULL, syncLastCommittedCursor = NULL WHERE id = ?",
                    arguments: [vaultId]
                )
                try SyncTransactionRecorder.record(
                    vaultId: vaultId,
                    operations: [SyncOperationDraft(entity: .vault, action: .reset, entityId: vaultId)],
                    in: db
                )
                try enqueue(vaultId: vaultId, allowAfterReset: true, in: db)
            }
        }
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
