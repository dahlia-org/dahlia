import Foundation
import GRDB

/// Legacy defaults are removed only after local persistence or a confirmed Server transaction.
enum ProjectAppearanceMigration {
    static func migrate(
        _ saved: [String: ProjectAppearance],
        workspaceId: UUID,
        dbQueue: DatabaseQueue
    ) async throws -> Set<String> {
        try await dbQueue.write { db in
            guard let workspace = try WorkspaceRecord.fetchOne(db, key: workspaceId),
                  workspace.allowsCanonicalEdits, workspace.syncRecoveryState == nil else { return [] }
            let isRemote = workspace.accountConnectionId != nil
            if isRemote, !workspace.allowsCanonicalEdits || workspace.syncConfirmedConnectionId != workspace.accountConnectionId { return [] }
            var completed: Set<String> = []
            for (key, appearance) in saved {
                guard let id = UUID(uuidString: key),
                      var project = try ProjectRecord.fetchOne(db, key: id), project.workspaceId == workspaceId else { continue }
                let pending = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
                WHERE t.workspace_id = ? AND o.entity = 'project' AND o.entityId = ?)
                """, arguments: [workspaceId, id]) ?? false
                if pending { continue }
                if isRemote {
                    let revision = try Int.fetchOne(db, sql: """
                    SELECT confirmedRevision FROM sync_entity_state
                    WHERE workspace_id = ? AND entity = 'project' AND entityId = ?
                    """, arguments: [workspaceId, id])
                    guard revision != nil else { continue }
                }
                // Existing canonical appearance wins over this device's old preference.
                if project.legacyAppearanceMigrated || project.icon != nil || project.color != nil {
                    if !project.legacyAppearanceMigrated {
                        try db.execute(sql: "UPDATE projects SET legacyAppearanceMigrated = 1 WHERE id = ?", arguments: [id])
                    }
                    completed.insert(key)
                    continue
                }
                project.legacyAppearanceMigrated = true
                project.icon = appearance.icon.rawValue
                project.color = appearance.color.rawValue
                project.revision += 1
                try project.update(db)
                let transaction = try SyncTransactionRecorder.record(
                    workspaceId: workspaceId,
                    operations: [SyncInitialSnapshotBuilder.projectOperation(project, action: .update)],
                    in: db
                )
                if transaction == nil { completed.insert(key) }
            }
            return completed
        }
    }
}
