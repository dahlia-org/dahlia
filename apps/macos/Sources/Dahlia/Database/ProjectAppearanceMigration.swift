import Foundation
import GRDB

/// Legacy defaults are removed only after local persistence.
enum ProjectAppearanceMigration {
    static func migrate(
        _ saved: [String: ProjectAppearance],
        workspaceId: UUID,
        dbQueue: any DatabaseWriter
    ) async throws -> Set<String> {
        try await dbQueue.write { db in
            guard try WorkspaceRecord.exists(db, key: workspaceId) else { return [] }
            var completed: Set<String> = []
            for (key, appearance) in saved {
                guard let id = UUID(uuidString: key),
                      var project = try ProjectRecord.fetchOne(db, key: id), project.workspaceId == workspaceId else { continue }
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
                completed.insert(key)
            }
            return completed
        }
    }
}
