import DahliaRuntimeSupport
import Foundation
import GRDB

/// Immutable image files. The app decides which originals are safe to evict from durable sync state.
public final class ScreenshotFileStore: Sendable {
    public static let budgetDefaultsKey = "screenshotCacheGiB"
    public static var defaultDirectory: URL {
        DahliaApplicationSupport.currentDirectoryURL.appending(path: "FileStore", directoryHint: .isDirectory)
    }

    private let directory: URL
    private let index: DatabaseQueue
    private let readOnly: Bool

    public init(directory: URL = defaultDirectory, readOnly: Bool = false) throws {
        self.directory = directory
        self.readOnly = readOnly
        if !readOnly { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        var configuration = Configuration()
        configuration.readonly = readOnly
        index = try DatabaseQueue(path: directory.appending(path: "index.sqlite").path, configuration: configuration)
        if !readOnly {
            try index.write { db in
                try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS images (
                    key TEXT PRIMARY KEY, mimeType TEXT NOT NULL, variant TEXT NOT NULL,
                    byteCount INTEGER NOT NULL, digest TEXT NOT NULL, accessedAt REAL NOT NULL, sourceHash TEXT
                )
                """)
                if try !db.columns(in: "images").contains(where: { $0.name == "sourceHash" }) {
                    try db.execute(sql: "ALTER TABLE images ADD COLUMN sourceHash TEXT")
                }
            }
        }
        // An interrupted registration can leave a file without an index row. Never delete it at open.
    }

    public func read(_ source: ScreenshotRemoteReference, variant: ScreenshotVariant) throws -> ScreenshotContent? {
        let key = source.cacheKey(variant: variant)
        let row = try index.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM images WHERE key = ?", arguments: [key])
        }
        guard let row else { return nil }
        if variant == .thumbnail {
            guard row.hasColumn("sourceHash"), row["sourceHash"] as String? == source.contentHash else { return nil }
        }
        let bytes = try Data(contentsOf: directory.appending(path: key))
        guard bytes.count == row["byteCount"] as Int,
              ScreenshotRemoteReference.digest(bytes) == row["digest"] as String,
              variant != .original || row["digest"] as String == source.contentHash else {
            throw ScreenshotContentError.integrityFailure
        }
        let content = ScreenshotContent(data: bytes, mimeType: row["mimeType"], variant: variant)
        if !readOnly {
            try? index.write { db in
                try db.execute(sql: "UPDATE images SET accessedAt = ? WHERE key = ?", arguments: [Date().timeIntervalSince1970, key])
            }
        }
        return content
    }

    public func write(
        _ content: ScreenshotContent,
        source: ScreenshotRemoteReference,
        required: Bool = false,
        budget: Int? = nil
    ) throws {
        guard !readOnly else { throw ScreenshotContentError.unavailable }
        let budget = budget ?? Self.configuredBudget
        guard required || content.data.count <= budget else { return }
        let digest = ScreenshotRemoteReference.digest(content.data)
        guard content.variant != .original || digest == source.contentHash else { throw ScreenshotContentError.integrityFailure }
        let key = source.cacheKey(variant: content.variant)
        let file = directory.appending(path: key)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            let existing = try Data(contentsOf: file)
            if existing != content.data {
                guard !required else { throw ScreenshotContentError.integrityFailure }
                try content.data.write(to: file, options: .atomic)
            }
        } else {
            try content.data.write(to: file, options: .atomic)
        }
        if required {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.synchronize()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try index.write { db in
            try db.execute(sql: """
            INSERT OR REPLACE INTO images (key, mimeType, variant, byteCount, digest, accessedAt, sourceHash) VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                key,
                content.mimeType,
                content.variant.rawValue,
                content.data.count,
                digest,
                Date().timeIntervalSince1970,
                source.contentHash,
            ])
        }
        // No implicit eviction: only the app can inspect pending operations and transient readers.
    }

    public func trim(budget: Int? = nil, protecting keys: Set<String>, limit: Int = 16) throws {
        guard !readOnly else { throw ScreenshotContentError.unavailable }
        let budget = budget ?? Self.configuredBudget
        try index.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key, byteCount, variant FROM images ORDER BY accessedAt")
                .filter { !keys.contains($0["key"] as String) && !(($0["key"] as String).hasPrefix("local/")) }
            var total = rows.reduce(0) { $0 + ($1["byteCount"] as Int) }
            guard total > budget else { return }
            var thumbnails = rows.filter { $0["variant"] as String == ScreenshotVariant.thumbnail.rawValue }
                .reduce(0) { $0 + ($1["byteCount"] as Int) }
            var removed = 0
            for row in rows where total > budget * 4 / 5 && removed < limit {
                let isThumbnail = row["variant"] as String == ScreenshotVariant.thumbnail.rawValue
                if isThumbnail, thumbnails <= budget / 5 { continue }
                let key: String = row["key"]
                let file = directory.appending(path: key)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                try db.execute(sql: "DELETE FROM images WHERE key = ?", arguments: [key])
                total -= row["byteCount"] as Int
                if isThumbnail { thumbnails -= row["byteCount"] as Int }
                removed += 1
            }
        }
    }

    private static var configuredBudget: Int {
        let configured = UserDefaults.standard.integer(forKey: budgetDefaultsKey)
        return ([1, 2, 5, 10].contains(configured) ? configured : 2) * 1024 * 1024 * 1024
    }
}
