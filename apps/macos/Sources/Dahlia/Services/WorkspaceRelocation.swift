import Foundation
import GRDB

struct WorkspaceRelocation: Decodable, Sendable {
    struct Workspace: Decodable, Sendable {
        let workspaceId: UUID
        let organizationId: UUID
        var personalUserId: UUID?
        let name: String
        let createdAt: Date
        let role: String
    }

    struct Item: Decodable, Sendable {
        let entity: SyncEntity
        let id: UUID
        let workspaceId: UUID
    }

    struct Document: Decodable, Sendable {
        let id: UUID
        let workspaceId: UUID
    }

    let workspaces: [Workspace]
    let items: [Item]
    var documents: [Document]?

    /// Only canonical IDs change affiliation. Recording paths and local payloads stay intact.
    func apply(connectionId: UUID, in db: Database) throws -> Bool {
        var moves: [(Item, UUID)] = []
        for item in items {
            let table = switch item.entity {
            case .project: "projects"
            case .meeting: "meetings"
            case .file: "files"
            default: throw SyncTransactionQueueError.invalidReceipt
            }
            if let source = try UUID.fetchOne(db, sql: "SELECT workspace_id FROM \(table) WHERE id = ?", arguments: [item.id]),
               source != item.workspaceId {
                guard try SyncTransactionQueue.matchesExpectedConnection(workspaceId: source, connectionId: connectionId, in: db) else {
                    throw SyncTransactionQueueError.invalidReceipt
                }
                moves.append((item, source))
            }
        }
        var documentMoves: [(Document, UUID)] = []
        for item in documents ?? [] {
            if let document = try DocumentRecord.fetchOne(db, key: item.id), document.meetingId == nil,
               document.generation != nil, document.workspaceId != item.workspaceId {
                guard try SyncTransactionQueue.matchesExpectedConnection(workspaceId: document.workspaceId, connectionId: connectionId, in: db),
                      try !WorkspaceTransferFence.blocksRemoteChanges(workspaceID: document.workspaceId, in: db),
                      try !WorkspaceTransferFence.blocksRemoteChanges(workspaceID: item.workspaceId, in: db)
                else { throw SyncTransactionQueueError.invalidReceipt }
                documentMoves.append((item, document.workspaceId))
            }
        }
        guard !moves.isEmpty || !documentMoves.isEmpty else { return false }
        let domainAffected = Set(moves.flatMap { [$0.0.workspaceId, $0.1] })
        let affected = domainAffected.union(documentMoves.flatMap { [$0.0.workspaceId, $0.1] })
        for id in affected {
            // Committed audio awaiting local verification no longer needs an upload.
            let hasPendingAudio = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM recording_archives a
                WHERE a.workspace_id = ? AND a.state IN ('pending', 'failed', 'syncing')
                  AND (NOT EXISTS(SELECT 1 FROM json_each(a.preparedJSON)) OR EXISTS(
                    SELECT 1 FROM json_each(a.preparedJSON) prepared
                    LEFT JOIN json_each(a.audioJSON) canonical ON canonical.key = prepared.key
                    WHERE json_extract(prepared.value, '$.checksum') IS NOT json_extract(canonical.value, '$.checksum')
                  )))
            """, arguments: [id]) == true
            if domainAffected.contains(id), try hasPendingAudio || SyncTransactionQueue.hasPending(workspaceId: id, in: db)
                || !SyncReconciliation.keys(workspaceId: id, in: db).isEmpty {
                throw SyncHTTPError(status: 409, body: Data("{\"error\":\"transfer_local_changes\"}".utf8))
            }
            if let existing = try WorkspaceRecord.fetchOne(db, key: id), existing.accountConnectionId != connectionId {
                throw SyncTransactionQueueError.invalidReceipt
            }
            if domainAffected.contains(id), try RecordingSessionRecord.hasActiveRecording(workspaceId: id, in: db) {
                throw SyncHTTPError(status: 409, body: Data("{\"error\":\"transfer_recording_active\"}".utf8))
            }
        }
        for workspace in workspaces where affected.contains(workspace.workspaceId) {
            try Self.register(workspace, connectionId: connectionId, in: db)
        }
        try Self.move(moves, in: db)
        for (item, source) in documentMoves {
            try db.execute(
                sql: "UPDATE documents SET workspace_id = ? WHERE id = ? AND workspace_id = ?",
                arguments: [item.workspaceId, item.id, source]
            )
        }
        for id in affected {
            try db.execute(sql: """
            UPDATE workspaces SET syncPullCursor = CASE WHEN ? THEN NULL ELSE syncPullCursor END, syncRecoveryState = NULL,
                syncMutationGeneration = syncMutationGeneration + 1 WHERE id = ?
            """, arguments: [domainAffected.contains(id), id])
        }
        return true
    }

    /// Canonical metadata can refresh permissions, but cannot complete a local restore.
    private static func register(_ workspace: Workspace, connectionId: UUID, in db: Database) throws {
        guard ["admin", "editor", "viewer"].contains(workspace.role) else { throw SyncTransactionQueueError.invalidReceipt }
        if let existing = try WorkspaceRecord.fetchOne(db, key: workspace.workspaceId) {
            guard existing.organizationId == workspace.organizationId else { throw SyncTransactionQueueError.invalidReceipt }
            // Only the snapshot builder can complete an existing restore/initial-sync checkpoint.
            guard existing.syncConfirmedConnectionId == connectionId else {
                throw SyncHTTPError(status: 409, body: Data("{\"error\":\"transfer_local_changes\"}".utf8))
            }
        }
        if try WorkspaceRecord.fetchOne(db, key: workspace.workspaceId) == nil {
            try WorkspaceRecord(
                id: workspace.workspaceId,
                path: nil,
                name: workspace.name,
                createdAt: workspace.createdAt,
                lastOpenedAt: Date(),
                accountConnectionId: connectionId,
                personalUserId: workspace.personalUserId,
                organizationId: workspace.organizationId,
                syncRole: workspace.role,
                syncConfirmedConnectionId: connectionId
            ).insert(db)
        } else {
            try db.execute(
                sql: "UPDATE workspaces SET syncRole = ?, personalUserId = ? WHERE id = ?",
                arguments: [workspace.role, workspace.personalUserId, workspace.workspaceId]
            )
        }
    }

    /// Shared affiliation change for remote transfer and Local import. Caller owns validation and transaction.
    static func move(_ moves: [(Item, UUID)], in db: Database) throws {
        // Parent validation remains enabled: move roots before children and their meetings.
        let roots = try Set(UUID.fetchAll(db, sql: "SELECT id FROM projects WHERE parentProjectId IS NULL"))
        let ordered = moves.sorted { lhs, rhs in
            func rank(_ item: Item) -> Int {
                switch item.entity {
                case .project: roots.contains(item.id) ? 0 : 1
                case .meeting: 2
                default: 3
                }
            }
            return rank(lhs.0) < rank(rhs.0)
        }
        for (item, source) in ordered {
            try db.execute(
                sql: "INSERT OR IGNORE INTO workspace_relocation_scope(source_workspace_id, destination_workspace_id) VALUES (?, ?)",
                arguments: [source, item.workspaceId]
            )
        }
        for (item, source) in ordered {
            // Adoption belongs to the old Workspace. Never delete moved content from a stale snapshot.
            try SyncReconciliation.finish(item.entity, id: item.id, workspaceId: source, in: db)
            if item.entity == .meeting {
                try db.execute(sql: """
                DELETE FROM sync_reconciliations WHERE workspaceId = ? AND (
                    entity IN ('summary', 'transcript') AND entityId = ?
                    OR entity = 'meeting_attachment' AND entityId IN (SELECT id FROM meeting_attachments WHERE meetingId = ?)
                    OR entity = 'recording' AND entityId IN (SELECT id FROM recording_sessions WHERE meetingId = ?))
                """, arguments: [source, item.id, item.id, item.id])
            }
            let table = item.entity == .project ? "projects" : item.entity == .meeting ? "meetings" : "files"
            if item.entity == .meeting {
                try db.execute(sql: """
                UPDATE recording_audio_files SET original_workspace_path = (SELECT path FROM workspaces WHERE id = ?)
                WHERE storageLocation = 'vault' AND original_workspace_path IS NULL
                  AND recordingSessionId IN (SELECT id FROM recording_sessions WHERE meetingId = ?)
                """, arguments: [source, item.id])
            }
            let refresh = item.entity == .meeting ? ", projectId = projectId" : item.entity == .file ? ", metadata = metadata" : ""
            try db.execute(
                sql: "UPDATE \(table) SET workspace_id = ?\(refresh) WHERE id = ? AND workspace_id = ?",
                arguments: [item.workspaceId, item.id, source]
            )
            for state in ["sync_entity_state", "sync_content_state"] {
                try db.execute(
                    sql: "UPDATE \(state) SET workspace_id = ? WHERE workspace_id = ? AND entityId = ?",
                    arguments: [item.workspaceId, source, item.id]
                )
            }
            if item.entity == .meeting {
                try db.execute(sql: "UPDATE recording_archives SET workspace_id = ? WHERE meetingId = ?", arguments: [item.workspaceId, item.id])
                try db.execute(
                    sql: "UPDATE document_local_archives SET workspace_id = ? WHERE workspace_id = ? AND meetingId = ?",
                    arguments: [item.workspaceId, source, item.id]
                )
                for state in ["sync_entity_state", "sync_content_state"] {
                    try db.execute(sql: """
                    UPDATE \(state) SET workspace_id = ? WHERE workspace_id = ? AND (
                        entity = 'meeting_attachment' AND entityId IN (SELECT id FROM meeting_attachments WHERE meetingId = ?)
                        OR entity = 'recording' AND entityId IN (SELECT id FROM recording_sessions WHERE meetingId = ?))
                    """, arguments: [item.workspaceId, source, item.id, item.id])
                }
            }
        }
        try db.execute(sql: "DELETE FROM workspace_relocation_scope")
    }

}
