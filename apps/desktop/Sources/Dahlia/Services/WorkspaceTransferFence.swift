import Foundation
import GRDB

struct WorkspaceTransferFence: Sendable {
    private let token: UUID
    private let workspaceCount: Int

    static func create(
        workspaceIDs: [UUID],
        blockingRemoteChangesIn blockedWorkspaceIDs: Set<UUID> = [],
        in db: Database
    ) throws -> Self {
        let token = UUID.v7()
        for workspaceID in workspaceIDs {
            try db.execute(
                sql: """
                INSERT INTO temp.workspace_transfer_fences(workspaceId, token, blocksRemoteChanges)
                VALUES (?, ?, ?) ON CONFLICT DO NOTHING
                """,
                arguments: [workspaceID, token, blockedWorkspaceIDs.contains(workspaceID)]
            )
            guard db.changesCount == 1 else { throw LocalWorkspaceImportError.changed }
        }
        return Self(token: token, workspaceCount: workspaceIDs.count)
    }

    func isCurrent(in db: Database) throws -> Bool {
        try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM temp.workspace_transfer_fences WHERE token = ? AND generation = 0",
            arguments: [token]
        ) == workspaceCount
    }

    func release(in db: Database) throws {
        try db.execute(sql: "DELETE FROM temp.workspace_transfer_fences WHERE token = ?", arguments: [token])
    }

    static func recordLocalMutation(workspaceID: UUID, in db: Database) throws {
        try db.execute(
            sql: "UPDATE temp.workspace_transfer_fences SET generation = generation + 1 WHERE workspaceId = ?",
            arguments: [workspaceID]
        )
    }

    static func blocksRemoteChanges(workspaceID: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM temp.workspace_transfer_fences WHERE workspaceId = ? AND blocksRemoteChanges = 1)",
            arguments: [workspaceID]
        ) ?? false
    }
}
