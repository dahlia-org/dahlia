import Foundation
import GRDB

enum SyncSnapshotRecoveryError: LocalizedError {
    case pendingChanges
    var errorDescription: String? { L10n.syncSnapshotPendingChanges }
}

enum SyncSnapshotRecovery {
    /// Explicit refresh must not discard or strand uploads, recordings, or an active transfer.
    static func validate(workspaceId: UUID, in db: Database) throws {
        guard try !SyncTransactionQueue.hasPending(workspaceId: workspaceId, in: db),
              try !RecordingSessionRecord.hasActiveRecording(workspaceId: workspaceId, in: db),
              try !WorkspaceTransferFence.blocksRemoteChanges(workspaceID: workspaceId, in: db),
              try Bool.fetchOne(db, sql: """
              SELECT EXISTS(SELECT 1 FROM documents d WHERE d.workspace_id = ? AND (
                EXISTS(SELECT 1 FROM document_updates u WHERE u.documentId = d.id AND u.pending = 1)
                OR EXISTS(SELECT 1 FROM document_recoveries r WHERE r.documentId = d.id AND r.pending = 1)))
              """, arguments: [workspaceId]) != true else { throw SyncSnapshotRecoveryError.pendingChanges }
    }
}
