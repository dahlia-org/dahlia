import DahliaRuntimeSupport
import Foundation
import GRDB

/// A rejected file commit can be removed without abandoning unrelated operations
/// in an unsent attachment batch. Requests with uncertain receipts are never rewritten.
struct SyncFileDiscardPlan {
    let fileId: UUID
    let operations: [Row]
    let meetingIds: Set<UUID>

    var transactionIds: Set<UUID> { Set(operations.map { $0["transactionId"] }) }
}

extension SyncTransactionQueue {
    /// Staging references do not change the rejected wire request or its receipt identity.
    static func repairRejectedFileUploads(workspaceId: UUID, in db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
        SELECT o.id, o.entityId, o.payloadJSON, t.connectionId, c.origin FROM sync_operations o
        JOIN sync_transactions t ON t.id = o.transactionId
        JOIN dahlia_account_connections c ON c.id = t.connectionId
        WHERE t.workspace_id = ? AND t.blockedReason = 'validation' AND t.leaseExpiresAt IS NULL
          AND json_extract(t.serverResponseJSON, '$.code') = 'file_content_missing'
          AND json_extract(t.serverResponseJSON, '$.status') = 422
          AND o.entity = 'file' AND o.action = 'upsert' AND o.attachmentMimeType IS NULL
        """, arguments: [workspaceId])
        for row in rows {
            guard let file = try FileRecord.fetchOne(db, key: row["entityId"] as UUID), file.workspaceId == workspaceId,
                  let reference = file.localReference, let payload: String = row["payloadJSON"],
                  let value = try? SyncJSON.decoder.decode(FileOperationPayload.self, from: Data(payload.utf8)),
                  let source = try? JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(reference.utf8)),
                  source.fileId == file.id, source.accountConnectionId == row["connectionId"] as UUID,
                  source.origin == row["origin"] as String, value.checksum == "SHA-256:" + source.contentHash
            else { continue }
            try db.execute(sql: """
            UPDATE sync_operations SET attachmentMimeType = ?, attachmentSHA256 = ?, attachmentReference = ? WHERE id = ?
            """, arguments: [file.contentType, source.contentHash, reference, row["id"] as UUID])
        }
    }

    static func fileDiscardPlan(workspaceId: UUID, in db: Database) throws -> SyncFileDiscardPlan? {
        struct Problem: Decodable {
            let status: Int?
            let code: String
            let operationId: UUID?
        }
        guard let head = try Row.fetchOne(db, sql: """
        SELECT * FROM sync_transactions WHERE workspace_id = ? AND blockedReason IS NOT NULL
        ORDER BY sequence LIMIT 1
        """, arguments: [workspaceId]), head["blockedReason"] as String == "validation",
        let response: String = head["serverResponseJSON"],
        let problem = try? SyncJSON.decoder.decode(Problem.self, from: Data(response.utf8)),
        problem.status == 422, problem.code == "file_content_missing", let operationId = problem.operationId,
        let fileId = try UUID.fetchOne(db, sql: """
        SELECT entityId FROM sync_operations WHERE id = ? AND transactionId = ? AND entity = 'file'
        """, arguments: [operationId, head["id"] as UUID]),
        try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM workspaces WHERE id = ? AND syncPullCursor IS NOT NULL
            AND accountConnectionId = ? AND syncConfirmedConnectionId = accountConnectionId)
        """, arguments: [workspaceId, head["connectionId"] as UUID]) == true,
        try !Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM sync_initial_entities WHERE workspaceId = ? AND built = 0 AND (
            entity = 'file' AND entityId = ? OR entity = 'meeting_attachment'
            AND entityId IN (SELECT id FROM meeting_attachments WHERE fileId = ?)))
        """, arguments: [workspaceId, fileId, fileId])!
        else { return nil }
        // Dependency keys cover deleted rows after the recorder consumes the relation journal.
        // They describe a whole request, so only singleton requests can recover an unknown link from them.
        let fileKey = "exists:" + SyncDependencies.key(.file, fileId)
        let candidates = try Row.fetchAll(db, sql: """
        SELECT o.id, o.transactionId, o.position, o.entity, o.entityId, t.attempts, t.leaseExpiresAt, t.blockedReason FROM sync_operations o
        JOIN sync_transactions t ON t.id = o.transactionId
        WHERE t.workspace_id = ? AND (o.entity = 'file' AND o.entityId = ?
            OR o.entity = 'meeting_attachment' AND (
                o.entityId IN (SELECT id FROM meeting_attachments WHERE fileId = ?)
                OR lower(json_extract(o.payloadJSON, '$.fileId')) = ?
                OR o.payloadJSON IS NULL
                OR EXISTS(SELECT 1 FROM sync_dependency_keys k WHERE k.transactionId = t.id AND k.resource = ?)
                OR EXISTS(SELECT 1 FROM sync_confirmed_relations r WHERE r.workspaceId = ?
                    AND r.entity = o.entity AND r.entityId = o.entityId AND r.fileId = ?)))
        ORDER BY t.sequence, o.position
        """, arguments: [workspaceId, fileId, fileId, fileId.uuidString.lowercased(), fileKey, workspaceId, fileId])
        var rows: [Row] = []
        var meetings = try Set(UUID.fetchAll(db, sql: "SELECT meetingId FROM meeting_attachments WHERE fileId = ?", arguments: [fileId]))
        for row in candidates {
            if row["entity"] as String == "meeting_attachment" {
                let relations = try attachmentRelations(id: row["entityId"], transactionId: row["transactionId"], workspaceId: workspaceId, in: db)
                guard !relations.files.isEmpty else { return nil }
                guard relations.files.contains(fileId) else { continue }
                meetings.formUnion(relations.meetings)
            }
            rows.append(row)
        }
        let headId: UUID = head["id"]
        for row in rows {
            guard row["leaseExpiresAt"] == nil else { return nil }
            let id: UUID = row["transactionId"]
            if id == headId {
                // A 422 guarantees atomic rejection, but do not split a previously sent request.
                guard try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE transactionId = ?", arguments: [id]) == 1 else {
                    return nil
                }
            } else if row["attempts"] as Int != 0 || row["blockedReason"] != nil {
                return nil
            }
        }
        return .init(fileId: fileId, operations: rows, meetingIds: meetings)
    }

    private static func attachmentRelations(
        id: UUID, transactionId: UUID, workspaceId: UUID, in db: Database
    ) throws -> (files: Set<UUID>, meetings: Set<UUID>) {
        struct Relation: Decodable {
            let fileId: UUID?
            let meetingId: UUID?
        }
        let history = try Row.fetchAll(db, sql: """
        SELECT a.fileId, a.meetingId FROM meeting_attachments a JOIN meetings m ON m.id = a.meetingId
        WHERE a.id = ? AND m.workspace_id = ?
        UNION SELECT fileId, meetingId FROM sync_confirmed_relations
        WHERE entity = 'meeting_attachment' AND entityId = ? AND workspaceId = ?
        UNION SELECT fileId, meetingId FROM sync_relation_history
        WHERE entity = 'meeting_attachment' AND entityId = ? AND workspaceId = ?
        """, arguments: [id, workspaceId, id, workspaceId, id, workspaceId])
        var files = Set(history.compactMap { $0["fileId"] as UUID? })
        var meetings = Set(history.compactMap { $0["meetingId"] as UUID? })
        for payload in try String.fetchAll(db, sql: """
        SELECT o.payloadJSON FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
        WHERE t.workspace_id = ? AND o.entity = 'meeting_attachment' AND o.entityId = ? AND o.payloadJSON IS NOT NULL
        """, arguments: [workspaceId, id]) {
            let value = try SyncJSON.decoder.decode(Relation.self, from: Data(payload.utf8))
            if let file = value.fileId { files.insert(file) }
            if let meeting = value.meetingId { meetings.insert(meeting) }
        }
        if files.isEmpty,
           try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE transactionId = ?", arguments: [transactionId]) == 1 {
            let keys = try String.fetchAll(db, sql: "SELECT resource FROM sync_dependency_keys WHERE transactionId = ?", arguments: [transactionId])
            let filePrefix = "exists:file:", meetingPrefix = "exists:meeting:"
            let fileIds = Set(keys.filter { $0.hasPrefix(filePrefix) }.compactMap { UUID(uuidString: String($0.dropFirst(filePrefix.count))) })
            if fileIds.count == 1 {
                files = fileIds
                meetings
                    .formUnion(keys.filter { $0.hasPrefix(meetingPrefix) }.compactMap { UUID(uuidString: String($0.dropFirst(meetingPrefix.count))) })
            }
        }
        return (files, meetings)
    }

    static func discardFileChanges(
        workspaceId: UUID,
        fileId: UUID,
        expectedLastTransactionId: UUID,
        dbQueue: DatabaseQueue
    ) async throws {
        try await dbQueue.write { db in
            guard try UUID.fetchOne(db, sql: """
            SELECT id FROM sync_transactions WHERE workspace_id = ? ORDER BY sequence DESC LIMIT 1
            """, arguments: [workspaceId]) == expectedLastTransactionId,
            let plan = try fileDiscardPlan(workspaceId: workspaceId, in: db), plan.fileId == fileId
            else { throw TextContentError.changed }
            // Store precisely the abandoned targets for canonical reconciliation; retain the pull cursor.
            for operation in plan.operations {
                try db.execute(sql: """
                INSERT OR IGNORE INTO sync_reconciliations(workspaceId, connectionId, entity, entityId, includeDescendants)
                SELECT ?, accountConnectionId, ?, ?, 0 FROM workspaces WHERE id = ?
                """, arguments: [workspaceId, operation["entity"] as String, operation["entityId"] as UUID, workspaceId])
                try db.execute(sql: "DELETE FROM sync_operations WHERE id = ?", arguments: [operation["id"] as UUID])
            }
            for id in plan.transactionIds {
                let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE transactionId = ?", arguments: [id]) ?? 0
                if count == 0 {
                    try db.execute(sql: "DELETE FROM sync_transactions WHERE id = ?", arguments: [id])
                    continue
                }
                // Remaining operations have never been sent. Give the reduced request a new
                // identity, retain its place in the queue and all conservative ordering edges.
                let replacement = UUID.v7()
                let sequence = try Int64.fetchOne(db, sql: "SELECT sequence FROM sync_transactions WHERE id = ?", arguments: [id])!
                try db.execute(sql: """
                INSERT INTO sync_transactions(id, workspace_id, connectionId, createdAt, availableAt, syncPriority)
                SELECT ?, workspace_id, connectionId, createdAt, availableAt, syncPriority FROM sync_transactions WHERE id = ?
                """, arguments: [replacement, id])
                try db.execute(sql: "UPDATE sync_operations SET transactionId = ? WHERE transactionId = ?", arguments: [replacement, id])
                try db.execute(sql: """
                INSERT OR IGNORE INTO sync_dependencies(transactionId, predecessorId, provisional)
                SELECT CASE WHEN transactionId = ? THEN ? ELSE transactionId END,
                    CASE WHEN predecessorId = ? THEN ? ELSE predecessorId END, provisional
                FROM sync_dependencies WHERE transactionId = ? OR predecessorId = ?
                """, arguments: [id, replacement, id, replacement, id, id])
                try db.execute(sql: "DELETE FROM sync_transactions WHERE id = ?", arguments: [id])
                try db.execute(sql: "UPDATE sync_transactions SET sequence = ? WHERE id = ?", arguments: [sequence, replacement])
                try SyncDependencies.index(transactionId: replacement, workspaceId: workspaceId, in: db, legacy: true)
            }
            try TextContentStore.releaseBody(entity: .file, id: fileId, in: db)
            try db.execute(sql: """
            UPDATE sync_content_state SET present = 1, residentRevision = NULL
            WHERE workspace_id = ? AND entity = 'file' AND entityId = ?
            """, arguments: [workspaceId, fileId])
            try db.execute(sql: "UPDATE workspaces SET syncMutationGeneration = syncMutationGeneration + 1 WHERE id = ?", arguments: [workspaceId])
        }
    }
}
