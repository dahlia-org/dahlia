import Foundation
import GRDB

struct SyncFileUpload: Equatable, Sendable {
    let transactionId: UUID
    let workspaceId: UUID
    let connectionId: UUID
    let origin: URL
    let operation: SyncQueuedOperation

    func isCurrent(in db: Database) throws -> Bool {
        // Snapshot recovery waits for queued writes, so pending/recovering must still allow staging.
        try Bool.fetchOne(db, sql: """
        SELECT EXISTS (
            SELECT 1 FROM sync_operations o
            JOIN sync_transactions t ON t.id = o.transactionId
            JOIN workspaces v ON v.id = t.workspace_id
            JOIN dahlia_account_connections c ON c.id = t.connectionId
            WHERE o.id = ? AND t.id = ? AND t.workspace_id = ? AND t.connectionId = ?
              AND c.origin = ? AND v.accountConnectionId = t.connectionId
              AND v.syncConfirmedConnectionId = t.connectionId
              AND v.syncRole IN ('admin', 'editor')
              AND (v.syncRecoveryState IS NULL OR v.syncRecoveryState IN ('pending', 'recovering'))
              AND t.blockedReason IS NULL
              AND NOT EXISTS (SELECT 1 FROM sync_transactions earlier
                  WHERE earlier.workspace_id = t.workspace_id AND earlier.sequence < t.sequence AND earlier.blockedReason IS NOT NULL)
        )
        """, arguments: [operation.id, transactionId, workspaceId, connectionId, origin.absoluteString]) == true
    }
}

extension SyncTransactionQueue {
    /// Peek at immutable file operations without claiming or reordering their transactions.
    static func fileUploads(for transaction: SyncQueuedTransaction, origin: URL, in db: Database) throws -> [SyncFileUpload] {
        let transactions = try Row.fetchAll(db, sql: """
        SELECT id, attempts, blockedReason FROM sync_transactions
        WHERE workspace_id = ? ORDER BY sequence LIMIT 8
        """, arguments: [transaction.workspaceId])
        var uploads: [SyncFileUpload] = []
        var files = Set<UUID>()
        for row in transactions {
            let id: UUID = row["id"]
            guard row["blockedReason"] == nil else { break }
            // Retries must resolve their receipt before staging anything again.
            if id != transaction.id, row["attempts"] as Int > 0 { break }
            let barrier = try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM sync_operations WHERE transactionId = ?
                AND (action IN ('delete', 'reset') OR (entity = 'workspace' AND action = 'create')))
            """, arguments: [id]) == true
            if barrier { break }
            let operations = try Row.fetchAll(db, sql: """
            SELECT id, entityId, action, baseRevision, payloadJSON, attachmentReference IS NOT NULL AS hasAttachment
            FROM sync_operations WHERE transactionId = ? AND entity = 'file' ORDER BY position
            """, arguments: [id])
            for operation in operations {
                let fileId: UUID = operation["entityId"]
                // Even a metadata-only operation must commit before another operation on this file stages.
                guard files.insert(fileId).inserted, operation["hasAttachment"] as Bool else { continue }
                let upload = SyncFileUpload(
                    transactionId: id, workspaceId: transaction.workspaceId, connectionId: transaction.connectionId, origin: origin,
                    operation: .init(
                        id: operation["id"], entity: .file, action: operation["action"], entityId: fileId,
                        baseRevision: operation["baseRevision"],
                        payloadJSON: (operation["payloadJSON"] as String?).map { Data($0.utf8) }
                    )
                )
                guard try upload.isCurrent(in: db) else { return uploads }
                uploads.append(upload)
                // Bound the in-memory candidates too, including multi-operation transactions.
                if uploads.count == 8 { return uploads }
            }
        }
        return uploads
    }
}
