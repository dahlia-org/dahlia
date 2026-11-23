import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

/// Owns image file persistence and retrieval; audio and transcript persistence never wait on this service.
actor ScreenshotContentProvider {
    static let shared = ScreenshotContentProvider()

    private var database: (any DatabaseWriter)?
    private let cache: ScreenshotFileStore?
    private var stores: [ObjectIdentifier: (database: any DatabaseWriter, files: ScreenshotFileStore)] = [:]

    init(cache: ScreenshotFileStore? = nil) {
        self.cache = cache
    }

    func configure(dbQueue: any DatabaseWriter) async {
        database = dbQueue
        do {
            let workspaceIds = try await dbQueue.read { db in
                try UUID.fetchAll(db, sql: "SELECT id FROM workspaces")
            }
            for workspaceId in workspaceIds {
                do {
                    try await migrateLegacyImages(workspaceId: workspaceId, dbQueue: dbQueue)
                } catch {
                    ErrorReportingService.capture(error, context: ["source": "screenshotFileMigration"])
                }
            }
        } catch {
            ErrorReportingService.capture(error, context: ["source": "screenshotFileMigration"])
        }
        startLocalScreenshotConversionIfNeeded(dbQueue: dbQueue)
    }

    func fileStore(for dbQueue: any DatabaseWriter) throws -> ScreenshotFileStore {
        if let cache { return cache }
        let key = ObjectIdentifier(dbQueue)
        if let entry = stores[key] { return entry.files }
        let directory = dbQueue.path == ":memory:"
            ? FileManager.default.temporaryDirectory.appending(path: "dahlia-images-\(UUID().uuidString)")
            : URL(filePath: dbQueue.path).deletingLastPathComponent().appending(path: "FileStore")
        let files = try ScreenshotFileStore(directory: directory)
        stores[key] = (dbQueue, files)
        return files
    }

    /// Cache hits may skip image I/O, but must still belong to the current Workspace and file.
    func isAvailable(id: UUID, workspaceID: UUID, contentHash: String, dbQueue: any DatabaseWriter) async throws -> Bool {
        try await dbQueue.read { db in
            guard let screenshot = try MeetingScreenshotRecord.fetchOne(db, key: id),
                  try MeetingRecord.fetchOne(db, key: screenshot.meetingId)?.workspaceId == workspaceID,
                  let file = try FileRecord.fetchOne(db, key: screenshot.originalFileId),
                  file.workspaceId == workspaceID, file.contentHash == contentHash else { return false }
            guard let reference = file.localReference ?? file.remoteReference else {
                return try Bool
                    .fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM file_migration_content WHERE fileId = ?)", arguments: [file.id]) == true
            }
            let source = try JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(reference.utf8))
            return source.fileId == file.id && source.contentHash == contentHash
        }
    }

    func content(
        id: UUID,
        variant: ScreenshotVariant = .original,
        dbQueue: (any DatabaseWriter)? = nil
    ) async throws -> ScreenshotContent {
        guard let dbQueue = dbQueue ?? database else { throw ScreenshotContentError.unavailable }
        return try await fileContent(variant: variant, dbQueue: dbQueue, recordAccess: true) { db in
            guard let record = try MeetingScreenshotRecord.fetchOne(db, key: id) else { throw ScreenshotContentError.deleted }
            return record.originalFileId
        }
    }

    func fileContent(
        id: UUID,
        variant: ScreenshotVariant = .original,
        dbQueue: any DatabaseWriter,
        recordAccess: Bool = true
    ) async throws -> ScreenshotContent {
        try await fileContent(variant: variant, dbQueue: dbQueue, recordAccess: recordAccess) { _ in id }
    }

    private struct FileSnapshot {
        let file: FileRecord
        let migratedBytes: Data?
        let source: ScreenshotRemoteReference?
    }

    /// Reads everything the request needs in one read transaction before the file read, and checks once afterward that
    /// the file was not deleted or re-pointed meanwhile. This provider is serial, so each saved read shortens every
    /// queued thumbnail's wait. Only files on this Mac are read; an image a Dahlia Server held alone is unavailable.
    private func fileContent(
        variant: ScreenshotVariant,
        dbQueue: any DatabaseWriter,
        recordAccess: Bool,
        fileID: @escaping @Sendable (Database) throws -> UUID
    ) async throws -> ScreenshotContent {
        // Requests from cells that scrolled away are cancelled; drop them before reading or making a thumbnail.
        try Task.checkCancellation()
        let snapshot = try await dbQueue.read { db in
            let id = try fileID(db)
            guard let file = try FileRecord.fetchOne(db, key: id) else { throw ScreenshotContentError.deleted }
            if let bytes = try Data.fetchOne(db, sql: "SELECT imageData FROM file_migration_content WHERE fileId = ?", arguments: [id]) {
                return FileSnapshot(file: file, migratedBytes: bytes, source: nil)
            }
            guard let reference = file.localReference ?? file.remoteReference else { throw ScreenshotContentError.unavailable }
            let source = try JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(reference.utf8))
            return FileSnapshot(file: file, migratedBytes: nil, source: source)
        }
        let file = snapshot.file
        if let bytes = snapshot.migratedBytes {
            return ScreenshotContent(data: bytes, mimeType: file.contentType, variant: .original)
        }
        guard let source = snapshot.source, source.fileId == file.id, source.contentHash == file.contentHash else {
            throw ScreenshotContentError.authorizationRequired
        }
        let content: ScreenshotContent
        let files = try fileStore(for: dbQueue)
        if variant == .thumbnail, let thumbnail = try files.read(source, variant: .thumbnail, recordAccess: recordAccess) {
            content = thumbnail
        } else {
            guard let original = try files.read(source, variant: .original, recordAccess: recordAccess) else {
                throw ScreenshotContentError.unavailable
            }
            try Task.checkCancellation()
            content = variant == .thumbnail ? Self.storedThumbnail(of: original, source: source, files: files) : original
        }
        try Task.checkCancellation()
        let unchanged = try await dbQueue.read { db in
            let current = try FileRecord.fetchOne(db, key: file.id)
            return current?.localReference == file.localReference && current?.remoteReference == file.remoteReference
        }
        guard unchanged else { throw ScreenshotContentError.deleted }
        return content
    }

    /// Keeps a small copy of a local original, so a grid revisit reads tens of kilobytes instead of the whole original.
    /// The copy is checked against the original's hash on read; if it cannot be made, the original is returned.
    /// `thumb_480` is the list variant with a long edge of at most 480 px (docs/spec/shared/sync.md).
    nonisolated static let thumbnailLongEdge = 480

    nonisolated static func storedThumbnail(
        of original: ScreenshotContent,
        source: ScreenshotRemoteReference,
        files: ScreenshotFileStore
    ) -> ScreenshotContent {
        guard let image = CGImageDecoder.decode(original.data, maxPixelSize: thumbnailLongEdge),
              let data = ImageEncoder.encodeJPEG(image),
              let mimeType = ImageEncoder.mimeType(for: data) else { return original }
        let thumbnail = ScreenshotContent(data: data, mimeType: mimeType, variant: .thumbnail)
        // Saved here, in order with this actor's removals, so deleting a screenshot never leaves its copy behind.
        try? files.write(thumbnail, source: source, recordAccess: false)
        return thumbnail
    }

    /// The helper reports use through the app; it never writes the file index itself.
    func touch(fileId: UUID, meetingId: UUID, workspaceId: UUID, dbQueue: any DatabaseWriter) async throws {
        let files = try fileStore(for: dbQueue)
        try Task.checkCancellation()
        try await dbQueue.read { db in
            guard let file = try FileRecord.fetchOne(db, key: fileId), file.workspaceId == workspaceId,
                  try Bool.fetchOne(db, sql: """
                  SELECT EXISTS(SELECT 1 FROM meeting_attachments a JOIN meetings m ON m.id = a.meetingId
                  WHERE a.meetingId = ? AND a.fileId = ? AND m.workspace_id = ?)
                  """, arguments: [meetingId, fileId, workspaceId]) == true,
                  let reference = file.localReference ?? file.remoteReference else { throw ScreenshotContentError.deleted }
            let source = try JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(reference.utf8))
            guard source.fileId == fileId, source.contentHash == file.contentHash else { throw ScreenshotContentError.authorizationRequired }
            try files.touch(source)
        }
    }

    func resolved(_ record: MeetingScreenshotRecord, dbQueue: (any DatabaseWriter)? = nil) async throws -> MeetingScreenshotRecord {
        if record.imageData != nil { return record }
        let content = try await content(id: record.id, dbQueue: dbQueue)
        var result = record
        result.imageData = content.data
        result.mimeType = content.mimeType
        return result
    }

    func resolved(_ records: [MeetingScreenshotRecord], dbQueue: (any DatabaseWriter)? = nil) async throws -> [MeetingScreenshotRecord] {
        var result: [MeetingScreenshotRecord] = []
        for record in records {
            try Task.checkCancellation()
            try await result.append(resolved(record, dbQueue: dbQueue))
        }
        return result
    }

}
