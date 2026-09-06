import AppleArchive
import CryptoKit
import Foundation
import System

struct BackupArchiveManifest: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let path: String
        let size: Int64
        let checksum: String
    }

    let metadata: BackupMetadata
    let entries: [Entry]
}

/// A standard Apple Archive container. Extraction accepts only the manifest's regular files.
enum BackupArchive {
    static let pathExtension = "dahliabackup"
    private static var dataKey: ArchiveHeader.FieldKey { ArchiveHeader.FieldKey("DAT") }
    private static let manifestLimit: Int64 = 64 * 1024 * 1024

    static func isArchive(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: 16) != Data("SQLite format 3\0".utf8)
    }

    static func create(directory: URL, metadata: BackupMetadata, paths: [String], at destination: URL) throws {
        let entries = try paths.map { path in
            let url = directory.appending(path: path)
            return try BackupArchiveManifest.Entry(
                path: path,
                size: Int64(url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0),
                checksum: "SHA-256:" + BackupService.sha256(of: url)
            )
        }
        let manifest = BackupArchiveManifest(metadata: metadata, entries: entries)
        try JSONEncoder().encode(manifest).write(to: directory.appending(path: "manifest.json"), options: .atomic)
        guard let bytes = ArchiveByteStream.fileStream(
            path: FilePath(destination.path),
            mode: .writeOnly,
            options: [.create, .exclusiveCreate],
            permissions: [.ownerRead, .ownerWrite]
        ),
            let compressed = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: bytes),
            let archive = ArchiveStream.encodeStream(writingTo: compressed) else { throw BackupServiceError.invalidBackup }
        defer { try? archive.close()
            try? compressed.close()
            try? bytes.close()
        }
        for path in ["manifest.json"] + paths {
            let url = directory.appending(path: path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let header = ArchiveHeader()
            header.append(.uint(key: ArchiveHeader.FieldKey("TYP"), value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
            header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: path))
            header.append(.blob(key: dataKey, size: UInt64(size)))
            try archive.writeHeader(header)
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try chunk.withUnsafeBytes { try archive.writeBlob(key: dataKey, from: $0) }
            }
        }
        try archive.close()
        try compressed.close()
        try bytes.close()
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    static func readManifest(at url: URL) throws -> BackupArchiveManifest {
        try withReader(url) { stream in try readManifest(from: stream) }
    }

    static func withExtracted<T>(at url: URL, _ body: (URL, BackupArchiveManifest) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dahlia-backup-\(UUID.v7())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try withReader(url) { stream in
            let manifest = try readManifest(from: stream)
            var remaining = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.path, $0) })
            while let header = try stream.readHeader() {
                let (path, size) = try regularFile(header)
                guard let entry = remaining.removeValue(forKey: path), size == entry.size else { throw BackupServiceError.invalidBackup }
                let output = directory.appending(path: path)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw BackupServiceError.invalidBackup
                }
                let handle = try FileHandle(forWritingTo: output)
                defer { try? handle.close() }
                var digest = SHA256()
                var unread = size
                while unread > 0 {
                    var chunk = Data(count: Int(min(unread, 1_048_576)))
                    try chunk.withUnsafeMutableBytes { try stream.readBlob(key: dataKey, into: $0) }
                    digest.update(data: chunk)
                    try handle.write(contentsOf: chunk)
                    unread -= Int64(chunk.count)
                }
                let checksum = "SHA-256:" + digest.finalize().map { String(format: "%02x", $0) }.joined()
                guard checksum == entry.checksum else { throw BackupServiceError.invalidBackup }
                try handle.synchronize()
            }
            guard remaining.isEmpty else { throw BackupServiceError.invalidBackup }
            return manifest
        }
        return try body(directory, manifest)
    }

    private static func readManifest(from stream: ArchiveStream) throws -> BackupArchiveManifest {
        guard let header = try stream.readHeader() else { throw BackupServiceError.invalidBackup }
        let (path, size) = try regularFile(header)
        guard path == "manifest.json", size > 0, size <= manifestLimit else { throw BackupServiceError.invalidBackup }
        var data = Data(count: Int(size))
        try data.withUnsafeMutableBytes { try stream.readBlob(key: dataKey, into: $0) }
        let manifest = try JSONDecoder().decode(BackupArchiveManifest.self, from: data)
        guard manifest.metadata.formatVersion == 4, !manifest.entries.isEmpty,
              Set(manifest.entries.map(\.path)).count == manifest.entries.count,
              manifest.entries.contains(where: { $0.path == "database.sqlite" }) else { throw BackupServiceError.invalidBackup }
        for entry in manifest.entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            let original = components.count == 3 && components[0] == "files" && components[2] == "original"
                && UUID(uuidString: String(components[1]))?.uuidString.lowercased() == String(components[1])
            guard entry.path == "database.sqlite" || original, entry.size >= 0,
                  entry.size <= (original ? 64 * 1024 * 1024 : 64 * 1024 * 1024 * 1024),
                  entry.checksum.hasPrefix("SHA-256:"), entry.checksum.count == 72,
                  entry.checksum.dropFirst(8).allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw BackupServiceError.invalidBackup }
        }
        return manifest
    }

    private static func regularFile(_ header: ArchiveHeader) throws -> (String, Int64) {
        guard header.entryType == .regularFile, let path = header.entryPath?.string,
              header.count == 3, case let .blob(_, size, offset) = header.field(forKey: dataKey), offset == 0,
              size <= Int64.max else { throw BackupServiceError.invalidBackup }
        return (path, Int64(size))
    }

    private static func withReader<T>(_ url: URL, _ body: (ArchiveStream) throws -> T) throws -> T {
        guard let bytes = ArchiveByteStream.fileStream(path: FilePath(url.path), mode: .readOnly, options: [], permissions: []),
              let decompressed = ArchiveByteStream.decompressionStream(readingFrom: bytes),
              let archive = ArchiveStream.decodeStream(readingFrom: decompressed) else { throw BackupServiceError.invalidBackup }
        defer { try? archive.close()
            try? decompressed.close()
            try? bytes.close()
        }
        return try body(archive)
    }
}
