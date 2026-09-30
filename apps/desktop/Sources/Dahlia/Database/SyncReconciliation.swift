import Foundation
import GRDB

/// Durable, entity-scoped Server adoption; unrelated queued changes keep their cursor and revisions.
enum SyncReconciliation {
    struct Key: Hashable, Sendable {
        let entity: SyncEntity
        let id: UUID
    }

    static func contains(_ entity: SyncEntity, id: UUID, workspaceId: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(SELECT 1 FROM sync_reconciliations
            WHERE workspaceId = ? AND entity = ? AND entityId = ?
                AND connectionId = (SELECT accountConnectionId FROM workspaces WHERE id = workspaceId))
            """,
            arguments: [workspaceId, entity, id]
        ) == true
    }

    static func keys(workspaceId: UUID, in db: Database) throws -> Set<Key> {
        try Set(Row.fetchAll(
            db,
            sql: "SELECT entity, entityId FROM sync_reconciliations WHERE workspaceId = ? AND connectionId = (SELECT accountConnectionId FROM workspaces WHERE id = workspaceId)",
            arguments: [workspaceId]
        )
        .map { Key(entity: $0["entity"], id: $0["entityId"]) })
    }

    static func subtreeRoots(workspaceId: UUID, in db: Database) throws -> Set<Key> {
        try Set(Row.fetchAll(
            db,
            sql: """
            SELECT entity, entityId FROM sync_reconciliations WHERE workspaceId = ? AND includeDescendants = 1
                AND connectionId = (SELECT accountConnectionId FROM workspaces WHERE id = workspaceId)
            """,
            arguments: [workspaceId]
        )
        .map { Key(entity: $0["entity"], id: $0["entityId"]) })
    }

    static func deletionOrder(_ keys: Set<Key>, in db: Database) throws -> [Key] {
        let roots = try Set(UUID.fetchAll(db, sql: "SELECT id FROM projects WHERE parentProjectId IS NULL"))
        func rank(_ key: Key) -> Int {
            switch key.entity {
            case .meetingAttachment, .summary, .transcript, .recording, .meetingEvent: 0
            case .meeting: 1
            case .file: 2
            case .project: roots.contains(key.id) ? 4 : 3
            case .workspace: 5
            }
        }
        return keys.sorted { rank($0) == rank($1) ? $0.id.uuidString < $1.id.uuidString : rank($0) < rank($1) }
    }

    static func finish(_ entity: SyncEntity, id: UUID, workspaceId: UUID, includingDescendants: Bool = true, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM sync_reconciliations WHERE workspaceId = ? AND entity = ? AND entityId = ? AND (? OR includeDescendants = 0)",
            arguments: [workspaceId, entity, id, includingDescendants]
        )
    }
}
