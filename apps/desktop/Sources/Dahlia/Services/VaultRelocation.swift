import Foundation
import GRDB

struct VaultRelocation: Decodable, Sendable {
    struct Vault: Decodable, Sendable {
        let vaultId: UUID
        let name: String
        let createdAt: Date
        let role: String
    }

    struct Item: Decodable, Sendable {
        let entity: SyncEntity
        let id: UUID
        let vaultId: UUID
    }

    let vaults: [Vault]
    let items: [Item]

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
            if let source = try UUID.fetchOne(db, sql: "SELECT vaultId FROM \(table) WHERE id = ?", arguments: [item.id]),
               source != item.vaultId {
                guard try SyncTransactionQueue.matchesExpectedConnection(vaultId: source, connectionId: connectionId, in: db) else {
                    throw SyncTransactionQueueError.invalidReceipt
                }
                try validateLocalReferences(item, in: db)
                moves.append((item, source))
            }
        }
        guard !moves.isEmpty else { return false }
        let affected = Set(moves.flatMap { [$0.0.vaultId, $0.1] })
        for id in affected {
            // Committed audio awaiting local verification no longer needs an upload.
            let hasPendingAudio = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM recording_archives a
                WHERE a.vaultId = ? AND a.state IN ('pending', 'failed', 'syncing')
                  AND (NOT EXISTS(SELECT 1 FROM json_each(a.preparedJSON)) OR EXISTS(
                    SELECT 1 FROM json_each(a.preparedJSON) prepared
                    LEFT JOIN json_each(a.audioJSON) canonical ON canonical.key = prepared.key
                    WHERE json_extract(prepared.value, '$.checksum') IS NOT json_extract(canonical.value, '$.checksum')
                  )))
            """, arguments: [id]) == true
            if try hasPendingAudio || SyncTransactionQueue.hasPending(vaultId: id, in: db) {
                throw SyncHTTPError(status: 409, body: Data("{\"error\":\"transfer_local_changes\"}".utf8))
            }
            if let existing = try VaultRecord.fetchOne(db, key: id), existing.accountConnectionId != connectionId {
                throw SyncTransactionQueueError.invalidReceipt
            }
        }
        if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM recording_sessions WHERE endedAt IS NULL)") == true {
            throw SyncHTTPError(status: 409, body: Data("{\"error\":\"transfer_recording_active\"}".utf8))
        }
        for vault in vaults where affected.contains(vault.vaultId) {
            if try VaultRecord.fetchOne(db, key: vault.vaultId) == nil {
                try VaultRecord(
                    id: vault.vaultId,
                    path: nil,
                    name: vault.name,
                    createdAt: vault.createdAt,
                    lastOpenedAt: Date(),
                    accountConnectionId: connectionId,
                    syncRole: vault.role,
                    syncConfirmedConnectionId: connectionId
                ).insert(db)
            }
        }
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
                sql: "INSERT OR IGNORE INTO vault_relocation_scope(sourceVaultId, destinationVaultId) VALUES (?, ?)",
                arguments: [source, item.vaultId]
            )
        }
        for (item, source) in ordered {
            let table = item.entity == .project ? "projects" : item.entity == .meeting ? "meetings" : "files"
            if item.entity == .meeting {
                try db.execute(sql: """
                UPDATE recording_audio_files SET originalVaultPath = (SELECT path FROM vaults WHERE id = ?)
                WHERE storageLocation = 'vault' AND originalVaultPath IS NULL
                  AND recordingSessionId IN (SELECT id FROM recording_sessions WHERE meetingId = ?)
                """, arguments: [source, item.id])
            }
            let refresh = item.entity == .meeting ? ", projectId = projectId" : item.entity == .file ? ", metadata = metadata" : ""
            try db.execute(
                sql: "UPDATE \(table) SET vaultId = ?\(refresh) WHERE id = ? AND vaultId = ?",
                arguments: [item.vaultId, item.id, source]
            )
            for state in ["sync_entity_state", "sync_content_state"] {
                try db.execute(
                    sql: "UPDATE \(state) SET vaultId = ? WHERE vaultId = ? AND entityId = ?",
                    arguments: [item.vaultId, source, item.id]
                )
            }
            if item.entity == .meeting {
                try db.execute(sql: "UPDATE recording_archives SET vaultId = ? WHERE meetingId = ?", arguments: [item.vaultId, item.id])
                for state in ["sync_entity_state", "sync_content_state"] {
                    try db.execute(sql: """
                    UPDATE \(state) SET vaultId = ? WHERE vaultId = ? AND (
                        entity = 'meeting_file' AND entityId IN (SELECT id FROM meeting_files WHERE meetingId = ?)
                        OR entity = 'recording' AND entityId IN (SELECT id FROM recording_sessions WHERE meetingId = ?))
                    """, arguments: [item.vaultId, source, item.id, item.id])
                }
            }
        }
        try db.execute(sql: "DELETE FROM vault_relocation_scope")
        for id in affected {
            try db.execute(sql: """
            UPDATE vaults SET syncPullCursor = NULL, syncRecoveryState = NULL,
                syncMutationGeneration = syncMutationGeneration + 1 WHERE id = ?
            """, arguments: [id])
        }
        return true
    }

    private func validateLocalReferences(_ item: Item, in db: Database) throws {
        guard item.entity != .file else { return }
        let referenceTable = item.entity == .project ? "project_resource_references" : "meeting_participants"
        let referenceKey = item.entity == .project ? "projectId" : "meetingId"
        if try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM \(referenceTable) WHERE \(referenceKey) = ?)
            OR EXISTS(SELECT 1 FROM insight_references WHERE resourceType = ? AND resourceId = ?)
            OR EXISTS(SELECT 1 FROM conversation_topic_references WHERE resourceType = ? AND resourceId = ?)
        """, arguments: [item.id, item.entity.rawValue, item.id, item.entity.rawValue, item.id]) == true {
            throw SyncHTTPError(status: 409, body: Data("{\"error\":\"transfer_local_changes\"}".utf8))
        }
    }

}
