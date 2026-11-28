import DahliaRuntimeSupport
import Foundation
import GRDB

/// Immutable image files. The app decides which originals are safe to evict from durable sync state.
public final class ScreenshotFileStore: Sendable {
    public static var defaultDirectory: URL {
        DahliaApplicationSupport.currentDirectoryURL.appending(path: "FileStore", directoryHint: .isDirectory)
    }

    /// Where external tools such as Obsidian read an original. A Server Account original can be evicted and fetched again.
    public static func originalFileURL(reference: String) -> URL? {
        guard let source = try? JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(reference.utf8)) else { return nil }
        return defaultDirectory.appending(path: source.cacheKey(variant: .original))
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

    /// Path of the original if it is on disk now. The file has no extension.
    public func existingOriginalFileURL(for source: ScreenshotRemoteReference) -> URL? {
        let url = directory.appending(path: source.cacheKey(variant: .original))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func read(_ source: ScreenshotRemoteReference, variant: ScreenshotVariant, recordAccess: Bool = true) throws -> ScreenshotContent? {
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
        // The access time only orders Server copies for eviction; local files are never evicted, so skip the index write.
        if !readOnly, recordAccess, source.accountConnectionId != nil { try? touch(source, variant: variant) }
        return content
    }

    public func touch(_ source: ScreenshotRemoteReference, variant: ScreenshotVariant = .original, now: Date = .now) throws {
        guard !readOnly else { throw ScreenshotContentError.unavailable }
        try index.write { db in
            try db.execute(
                sql: "UPDATE images SET accessedAt = ? WHERE key IN (?, ?)",
                arguments: [now.timeIntervalSince1970, source.cacheKey(variant: variant), source.cacheKey(variant: .original)]
            )
        }
    }

    public func write(
        _ content: ScreenshotContent,
        source: ScreenshotRemoteReference,
        required: Bool = false,
        recordAccess: Bool = true,
        now: Date = .now
    ) throws {
        guard !readOnly else { throw ScreenshotContentError.unavailable }
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
            INSERT INTO images (key, mimeType, variant, byteCount, digest, accessedAt, sourceHash) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET mimeType = excluded.mimeType, variant = excluded.variant,
                byteCount = excluded.byteCount, digest = excluded.digest, sourceHash = excluded.sourceHash,
                accessedAt = CASE WHEN ? THEN excluded.accessedAt ELSE images.accessedAt END
            """, arguments: [
                key,
                content.mimeType,
                content.variant.rawValue,
                content.data.count,
                digest,
                now.timeIntervalSince1970,
                source.contentHash,
                recordAccess,
            ])
            if recordAccess {
                try db.execute(
                    sql: "UPDATE images SET accessedAt = ? WHERE key = ?",
                    arguments: [now.timeIntervalSince1970, source.cacheKey(variant: .original)]
                )
            }
        }
        // No implicit eviction: only the app can inspect pending operations and transient readers.
    }

    /// Deletes every stored representation of a file that no database reference points to anymore.
    public func remove(_ source: ScreenshotRemoteReference) throws {
        guard !readOnly else { throw ScreenshotContentError.unavailable }
        let keys = [ScreenshotVariant.original, .thumbnail].map { source.cacheKey(variant: $0) }
        try index.write { db in
            for key in keys {
                let file = directory.appending(path: key)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                try db.execute(sql: "DELETE FROM images WHERE key = ?", arguments: [key])
            }
        }
    }

}
