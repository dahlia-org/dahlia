import DahliaMeetingAccess
import DahliaRuntimeSupport
import DahliaServerAPI
import Foundation
import GRDB
import OpenAPIRuntime
import Synchronization

/// Owns image file persistence and retrieval; audio and transcript persistence never wait on this service.
actor ScreenshotContentProvider {
    static let shared = ScreenshotContentProvider()

    private var database: (any DatabaseWriter)?
    private let cache: ScreenshotFileStore?
    private var stores: [ObjectIdentifier: (database: any DatabaseWriter, files: ScreenshotFileStore)] = [:]
    var activeFileWork = 0
    private let session: URLSession
    private let tokenProvider: @Sendable (UUID, Bool) async throws -> String
    private var activeReads = 0
    private var activeThumbnails = 0
    private var waiters: [(id: UUID, variant: ScreenshotVariant, continuation: CheckedContinuation<Bool, Never>)] = []
    nonisolated let retainedWorkspaces = Mutex<[ObjectIdentifier: [UUID: Int]]>([:])

    init(
        session: URLSession? = nil,
        cache: ScreenshotFileStore? = nil,
        tokenProvider: @escaping @Sendable (UUID, Bool) async throws -> String = {
            try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(connectionID: $0, forceRefresh: $1)
        }
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = session ?? URLSession(configuration: configuration)
        self.cache = cache
        self.tokenProvider = tokenProvider
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

    func trimCache() {
        guard let database else { return }
        try? trimFiles(dbQueue: database)
    }

    /// Cache hits may skip image I/O, but must still belong to the current Workspace and file source.
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
            return try source.fileId == file.id && source.contentHash == contentHash
                && Self.matchesCurrentSource(source, workspaceId: workspaceID, in: db)
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
        let sourceIsCurrent: Bool
    }

    /// Reads everything the request needs in one read transaction before the file read, and checks once afterward that
    /// the file was not deleted or re-pointed meanwhile. This provider is serial, so each saved read shortens every
    /// queued thumbnail's wait.
    private func fileContent(
        variant: ScreenshotVariant,
        dbQueue: any DatabaseWriter,
        recordAccess: Bool,
        fileID: @escaping @Sendable (Database) throws -> UUID
    ) async throws -> ScreenshotContent {
        activeFileWork += 1
        defer { activeFileWork -= 1 }
        // Requests from cells that scrolled away are cancelled; drop them before reading or making a thumbnail.
        try Task.checkCancellation()
        let snapshot = try await dbQueue.read { db in
            let id = try fileID(db)
            guard let file = try FileRecord.fetchOne(db, key: id) else { throw ScreenshotContentError.deleted }
            if let bytes = try Data.fetchOne(db, sql: "SELECT imageData FROM file_migration_content WHERE fileId = ?", arguments: [id]) {
                return FileSnapshot(file: file, migratedBytes: bytes, source: nil, sourceIsCurrent: false)
            }
            guard let reference = file.localReference ?? file.remoteReference else { throw ScreenshotContentError.unavailable }
            let source = try JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(reference.utf8))
            return try FileSnapshot(
                file: file, migratedBytes: nil, source: source,
                sourceIsCurrent: Self.matchesCurrentSource(source, workspaceId: file.workspaceId, in: db)
            )
        }
        let file = snapshot.file
        if let bytes = snapshot.migratedBytes {
            return ScreenshotContent(data: bytes, mimeType: file.contentType, variant: .original)
        }
        guard let source = snapshot.source, source.fileId == file.id, source.contentHash == file.contentHash,
              snapshot.sourceIsCurrent else {
            throw ScreenshotContentError.authorizationRequired
        }
        let content: ScreenshotContent
        if file.remoteReference == nil || file.localReference != nil && file.localReference != file.remoteReference {
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
        } else {
            do {
                content = try await remoteContent(source, variant: variant, credentials: dbQueue, recordAccess: recordAccess)
            } catch where variant == .thumbnail {
                content = try await remoteContent(source, variant: .original, credentials: dbQueue, recordAccess: recordAccess)
            }
        }
        try Task.checkCancellation()
        let unchanged = try await dbQueue.read { db in
            let current = try FileRecord.fetchOne(db, key: file.id)
            return try current?.localReference == file.localReference && current?.remoteReference == file.remoteReference
                && Self.matchesCurrentSource(source, workspaceId: file.workspaceId, in: db)
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
        activeFileWork += 1
        defer { activeFileWork -= 1 }
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
            guard source.fileId == fileId, source.contentHash == file.contentHash,
                  let workspace = try WorkspaceRecord.fetchOne(db, key: workspaceId),
                  workspace.accountConnectionId == source.accountConnectionId else { throw ScreenshotContentError.authorizationRequired }
            if let connectionId = source.accountConnectionId {
                guard try DahliaAccountConnectionRecord.fetchOne(db, key: connectionId)?.origin == source.origin else {
                    throw ScreenshotContentError.authorizationRequired
                }
            } else if !source.origin.isEmpty { throw ScreenshotContentError.authorizationRequired }
            try files.touch(source)
        }
    }

    private nonisolated static func matchesCurrentSource(
        _ source: ScreenshotRemoteReference,
        workspaceId: UUID,
        in db: Database
    ) throws -> Bool {
        guard let workspace = try WorkspaceRecord.fetchOne(db, key: workspaceId),
              workspace.accountConnectionId == source.accountConnectionId else { return false }
        guard let connectionId = source.accountConnectionId else { return source.origin.isEmpty }
        return try DahliaAccountConnectionRecord.fetchOne(db, key: connectionId)?.origin == source.origin
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

    nonisolated func retainOriginals(workspaceIds: [UUID], dbQueue: any DatabaseWriter) {
        retainedWorkspaces.withLock { counts in
            for workspaceId in workspaceIds {
                counts[ObjectIdentifier(dbQueue), default: [:]][workspaceId, default: 0] += 1
            }
        }
    }

    nonisolated func releaseOriginals(workspaceIds: [UUID], dbQueue: any DatabaseWriter) {
        let key = ObjectIdentifier(dbQueue)
        retainedWorkspaces.withLock { counts in
            for workspaceId in workspaceIds {
                guard let count = counts[key]?[workspaceId] else { continue }
                counts[key]?[workspaceId] = count > 1 ? count - 1 : nil
            }
            if counts[key]?.isEmpty == true { counts[key] = nil }
        }
    }

    /// Only a matching configured origin may receive the account's credential.
    func remoteContent(
        _ source: ScreenshotRemoteReference,
        variant: ScreenshotVariant = .original,
        credentials: any DatabaseWriter,
        recordAccess: Bool = true
    ) async throws -> ScreenshotContent {
        let files = try? fileStore(for: credentials)
        if let content = try? files?.read(source, variant: variant, recordAccess: recordAccess) { return content }
        if variant != .original, let content = try? files?.read(source, variant: .original, recordAccess: recordAccess) { return content }
        let connection = try await credentials.read { db in
            try DahliaAccountConnectionRecord.fetchOne(
                db,
                sql: "SELECT * FROM provider_accounts WHERE id = ? AND origin = ?",
                arguments: [source.accountConnectionId, source.origin]
            )
        }
        guard let connection, let origin = URL(string: connection.origin),
              source.contentHash.count == 64, source.contentHash.allSatisfy(\.isHexDigit) else {
            throw ScreenshotContentError.authorizationRequired
        }
        try await acquireRead(variant: variant)
        defer { releaseRead(variant: variant) }
        try Task.checkCancellation()
        let client = SyncAPIClient(session: session, tokenProvider: tokenProvider)
        do {
            let (body, contentType, variantName, originalHash) = try await client.perform(origin: origin, connectionId: connection.id) { client in
                if variant == .original {
                    let response = try await client.getFileContent(path: .init(fileId: source.fileId.uuidString.lowercased())).ok
                    return try (
                        response.body.any,
                        response.headers.contentType,
                        response.headers.xDahliaImageVariant,
                        response.headers.xDahliaOriginalSha256
                    )
                }
                guard let value = Operations.GetFileVariant.Input.Path.VariantPayload(rawValue: variant.rawValue) else {
                    throw ScreenshotContentError.unavailable
                }
                let response = try await client.getFileVariant(path: .init(fileId: source.fileId.uuidString.lowercased(), variant: value)).ok
                return try (
                    response.body.any,
                    response.headers.contentType,
                    response.headers.xDahliaImageVariant,
                    response.headers.xDahliaOriginalSha256
                )
            }
            if case let .known(length) = body.length, length > 64 * 1024 * 1024 { throw ScreenshotContentError.unavailable }
            var bytes = Data()
            for try await chunk in body {
                guard chunk.count <= 64 * 1024 * 1024 - bytes.count else { throw ScreenshotContentError.integrityFailure }
                bytes.append(contentsOf: chunk)
            }
            let actual = variantName.flatMap(ScreenshotVariant.init(rawValue:)) ?? .original
            guard variant != .original || actual == .original,
                  actual != .original || ScreenshotRemoteReference.digest(bytes) == source.contentHash,
                  actual == .original || originalHash == source.contentHash,
                  let mimeType = contentType?.split(separator: ";", maxSplits: 1).first.map(String.init) else {
                throw ScreenshotContentError.integrityFailure
            }
            let content = ScreenshotContent(data: bytes, mimeType: mimeType, variant: actual)
            try? files?.write(content, source: source, recordAccess: recordAccess)
            return content
        } catch let error as SyncHTTPError {
            if [401, 403].contains(error.status) { throw ScreenshotContentError.authorizationRequired }
            if error.status == 404 { throw ScreenshotContentError.deleted }
            throw ScreenshotContentError.unavailable
        }
    }

    private func acquireRead(variant: ScreenshotVariant) async throws {
        try Task.checkCancellation()
        if activeReads < 4, variant == .original || activeThumbnails < 3 {
            activeReads += 1
            if variant == .thumbnail { activeThumbnails += 1 }
            return
        }
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, variant, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelRead(id: id) }
        }
        guard acquired else { throw CancellationError() }
    }

    /// Keep one network slot available for opening an original while a grid is loading.
    private func releaseRead(variant: ScreenshotVariant) {
        activeReads -= 1
        if variant == .thumbnail { activeThumbnails -= 1 }
        while activeReads < 4 {
            guard let index = waiters.firstIndex(where: { $0.variant == .original })
                ?? (activeThumbnails < 3 ? waiters.indices.first : nil) else { return }
            let waiter = waiters.remove(at: index)
            activeReads += 1
            if waiter.variant == .thumbnail { activeThumbnails += 1 }
            waiter.continuation.resume(returning: true)
        }
    }

    private func cancelRead(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
