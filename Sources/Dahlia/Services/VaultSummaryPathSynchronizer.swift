import Foundation
import GRDB

struct VaultSummaryPathSynchronizer {
    let dbQueue: DatabaseQueue
    let vaultId: UUID

    func renamePath(from oldPath: String, to newPath: String) {
        try? dbQueue.write { db in
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

    func clearRemovedPaths(_ relativePaths: [String]) {
        guard !relativePaths.isEmpty else { return }
        try? dbQueue.write { db in
            for relativePath in relativePaths {
                try SummaryExportRecord.clearVaultPath(relativePath, vaultId: vaultId, in: db)
            }
        }
    }
}
