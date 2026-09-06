import DahliaRuntimeSupport
import Foundation
import GRDB

/// Rebuildable image bytes shared by the app and its read-only meeting helper.
public final class ScreenshotDiskCache: Sendable {
    public static let budgetDefaultsKey = "screenshotCacheGiB"
    public static var defaultDirectory: URL {
        DahliaApplicationSupport.directoryURL(applicationSupportDirectory: .cachesDirectory)
            .appending(path: "Screenshots", directoryHint: .isDirectory)
    }

    private let directory: URL
    private let index: DatabaseQueue

    public init(directory: URL = defaultDirectory) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = try DatabaseQueue(path: directory.appending(path: "index.sqlite").path)
        try index.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS images (
                key TEXT PRIMARY KEY, mimeType TEXT NOT NULL, variant TEXT NOT NULL,
                byteCount INTEGER NOT NULL, digest TEXT NOT NULL, accessedAt REAL NOT NULL
            )
            """)
            let known = try Set(String.fetchAll(db, sql: "SELECT key FROM images"))
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let key = file.deletingPathExtension().lastPathComponent
                if file.pathExtension == "bin", key.count == 64, key.allSatisfy(\.isHexDigit), !known.contains(key) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    public func read(_ source: ScreenshotRemoteReference, variant: ScreenshotVariant) throws -> ScreenshotContent? {
        let key = source.cacheKey(variant: variant)
        return try index.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM images WHERE key = ?", arguments: [key]) else {
                return nil
            }
            let file = directory.appending(path: "\(key).bin")
            guard let bytes = try? Data(contentsOf: file), bytes.count == row["byteCount"] as Int,
                  ScreenshotRemoteReference.digest(bytes) == row["digest"] as String else {
                try? FileManager.default.removeItem(at: file)
                try db.execute(sql: "DELETE FROM images WHERE key = ?", arguments: [key])
                return nil
            }
            try db.execute(sql: "UPDATE images SET accessedAt = ? WHERE key = ?", arguments: [Date().timeIntervalSince1970, key])
            return ScreenshotContent(data: bytes, mimeType: row["mimeType"], variant: variant)
        }
    }

    public func write(_ content: ScreenshotContent, source: ScreenshotRemoteReference, budget: Int? = nil) throws {
        let budget = budget ?? Self.configuredBudget
        guard content.data.count <= budget else { return }
        let key = source.cacheKey(variant: content.variant)
        let digest = ScreenshotRemoteReference.digest(content.data)
        try index.write { db in
            try content.data.write(to: directory.appending(path: "\(key).bin"), options: .atomic)
            try db.execute(sql: """
            INSERT OR REPLACE INTO images VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [key, content.mimeType, content.variant.rawValue, content.data.count, digest, Date().timeIntervalSince1970])
            try trim(in: db, budget: budget)
        }
    }

    public func trim(budget: Int? = nil) throws {
        try index.write { db in try trim(in: db, budget: budget ?? Self.configuredBudget) }
    }

    private static var configuredBudget: Int {
        let configured = UserDefaults.standard.integer(forKey: budgetDefaultsKey)
        return ([1, 2, 5, 10].contains(configured) ? configured : 2) * 1024 * 1024 * 1024
    }

    private func trim(in db: Database, budget: Int) throws {
        var total = try Int.fetchOne(db, sql: "SELECT coalesce(sum(byteCount), 0) FROM images") ?? 0
        guard total > budget else { return }
        var thumbnails = try Int.fetchOne(db, sql: "SELECT coalesce(sum(byteCount), 0) FROM images WHERE variant = 'thumbnail'") ?? 0
        let rows = try Row.fetchAll(db, sql: """
        SELECT key, byteCount, variant FROM images ORDER BY accessedAt
        """)
        for row in rows where total > budget * 4 / 5 {
            let isThumbnail = row["variant"] as String == "thumbnail"
            if isThumbnail, thumbnails <= budget / 5 { continue }
            let oldKey: String = row["key"]
            let file = directory.appending(path: "\(oldKey).bin")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            try db.execute(sql: "DELETE FROM images WHERE key = ?", arguments: [oldKey])
            total -= row["byteCount"] as Int
            if isThumbnail { thumbnails -= row["byteCount"] as Int }
        }
    }
}
