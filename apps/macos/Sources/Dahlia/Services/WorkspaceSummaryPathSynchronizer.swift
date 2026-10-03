import Foundation
import GRDB

struct WorkspaceSummaryPathSynchronizer {
    let dbQueue: DatabaseQueue
    let workspaceId: UUID

    func renamePath(from oldPath: String, to newPath: String) throws {
        try dbQueue.write { db in
            try SummaryExportRecord.renameWorkspacePath(
                from: oldPath,
                to: newPath,
                workspaceId: workspaceId,
                in: db
            )
        }
    }

    func renamePathsByPrefix(oldPrefix: String, newPrefix: String, in db: Database) throws {
        try SummaryExportRecord.renameWorkspacePathsByPrefix(
            oldPrefix: oldPrefix,
            newPrefix: newPrefix,
            workspaceId: workspaceId,
            in: db
        )
    }

    func clearRemovedPaths(_ relativePaths: [String]) throws {
        guard !relativePaths.isEmpty else { return }
        try dbQueue.write { db in
            for relativePath in relativePaths {
                try SummaryExportRecord.clearWorkspacePath(relativePath, workspaceId: workspaceId, in: db)
            }
        }
    }

    func clearRemovedPathPrefixes(_ prefixes: [String]) throws {
        guard !prefixes.isEmpty else { return }
        try dbQueue.write { db in
            let rows = try SummaryExportRecord.fetchAll(
                db,
                sql: """
                SELECT summary_exports.*
                FROM summary_exports
                JOIN meetings ON meetings.id = summary_exports.meetingId
                WHERE summary_exports.type = ? AND meetings.workspace_id = ?
                """,
                arguments: [SummaryExportType.workspace, workspaceId]
            )
            let paths = Set(rows.compactMap(\.workspaceRelativePath))
            for path in paths {
                guard prefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                    continue
                }
                try SummaryExportRecord.clearWorkspacePath(path, workspaceId: workspaceId, in: db)
            }
        }
    }
}
