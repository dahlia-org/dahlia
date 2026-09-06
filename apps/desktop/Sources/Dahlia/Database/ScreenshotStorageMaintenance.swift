import Foundation
import GRDB

enum ScreenshotStorageMaintenance {
    /// Run before starting recording, search and sync workers. VACUUM is SQLite's atomic rebuild.
    static func compactAtStartup(
        dbQueue: DatabaseQueue,
        minimumFreeBytes: Int = 128 * 1024 * 1024
    ) async throws {
        try await dbQueue.writeWithoutTransaction { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM recording_sessions WHERE endedAt IS NULL)") != true else { return }
            let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
            let freePages = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            guard freePages * pageSize >= minimumFreeBytes,
                  let path = try Row.fetchAll(db, sql: "PRAGMA database_list").first(where: { $0["name"] as String == "main" })?["file"] as String?,
                  !path.isEmpty else { return }
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let available = try URL(filePath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard available > Int64(pages * pageSize) * 2 else { return }
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
            try db.execute(sql: "VACUUM")
            _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    static func reclaimIncrementally(dbQueue: DatabaseQueue) async throws {
        try await dbQueue.writeWithoutTransaction { db in
            guard try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") == 2,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM recording_sessions WHERE endedAt IS NULL)") != true else { return }
            _ = try Row.fetchAll(db, sql: "PRAGMA incremental_vacuum(256)")
        }
    }
}
