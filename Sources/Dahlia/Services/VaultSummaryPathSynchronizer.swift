import Foundation
import GRDB

struct VaultSummaryPathSynchronizer {
    let dbQueue: DatabaseQueue
    let vaultId: UUID

    func renamePath(from oldPath: String, to newPath: String) throws {
        try dbQueue.write { db in
            try SummaryExportRecord.renameVaultPath(
                from: oldPath,
                to: newPath,
                vaultId: vaultId,
                in: db
            )
        }
    }

    func renamePathsByPrefix(oldPrefix: String, newPrefix: String, in db: Database) throws {
        try SummaryExportRecord.renameVaultPathsByPrefix(
            oldPrefix: oldPrefix,
            newPrefix: newPrefix,
            vaultId: vaultId,
            in: db
        )
    }

    func clearRemovedPaths(_ relativePaths: [String]) throws {
        guard !relativePaths.isEmpty else { return }
        try dbQueue.write { db in
            for relativePath in relativePaths {
                try SummaryExportRecord.clearVaultPath(relativePath, vaultId: vaultId, in: db)
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
                WHERE summary_exports.type = ? AND meetings.vaultId = ?
                """,
                arguments: [SummaryExportType.vault, vaultId]
            )
            let paths = Set(rows.compactMap(\.vaultRelativePath))
            for path in paths {
                guard prefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                    continue
                }
                try SummaryExportRecord.clearVaultPath(path, vaultId: vaultId, in: db)
            }
        }
    }
}
