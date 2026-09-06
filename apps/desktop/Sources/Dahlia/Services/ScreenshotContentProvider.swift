import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB
import Synchronization

/// Owns image file persistence and retrieval; audio and transcript persistence never wait on this service.
actor ScreenshotContentProvider {
    static let shared = ScreenshotContentProvider()

    private var database: DatabaseQueue?
    private let cache: ScreenshotFileStore?
    private var stores: [ObjectIdentifier: (database: DatabaseQueue, files: ScreenshotFileStore)] = [:]
    var activeFileWork = 0
    private let session: URLSession
    private let tokenProvider: @Sendable (UUID, Bool) async throws -> String
    private var activeReads = 0
    private var activeThumbnails = 0
    private var waiters: [(id: UUID, variant: ScreenshotVariant, continuation: CheckedContinuation<Bool, Never>)] = []
    nonisolated let retainedVaults = Mutex<[ObjectIdentifier: [UUID: Int]]>([:])

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

    func configure(dbQueue: DatabaseQueue) async {
        database = dbQueue
        do {
            let vaultIds = try await dbQueue.read { db in
                try UUID.fetchAll(db, sql: "SELECT id FROM vaults")
            }
            for vaultId in vaultIds {
                do {
                    try await migrateLegacyImages(vaultId: vaultId, dbQueue: dbQueue)
                } catch {
                    ErrorReportingService.capture(error, context: ["source": "screenshotFileMigration"])
                }
            }
        } catch {
            ErrorReportingService.capture(error, context: ["source": "screenshotFileMigration"])
        }
    }

    func fileStore(for dbQueue: DatabaseQueue) throws -> ScreenshotFileStore {
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

    func content(
        id: UUID,
        variant: ScreenshotVariant = .original,
        dbQueue: DatabaseQueue? = nil
    ) async throws -> ScreenshotContent {
        guard let dbQueue = dbQueue ?? database else { throw ScreenshotContentError.unavailable }
        let record = try await dbQueue.read { db in
            try MeetingScreenshotRecord.fetchOne(db, key: id)
        }
        guard let record else { throw ScreenshotContentError.deleted }
        return try await fileContent(id: record.originalFileId, variant: variant, dbQueue: dbQueue)
    }

    func fileContent(id: UUID, variant: ScreenshotVariant = .original, dbQueue: DatabaseQueue) async throws -> ScreenshotContent {
        activeFileWork += 1
        defer { activeFileWork -= 1 }
        guard let file = try await dbQueue.read({ try FileRecord.fetchOne($0, key: id) }) else { throw ScreenshotContentError.deleted }
        if let bytes = try await dbQueue.read({ try Data.fetchOne(
            $0,
            sql: "SELECT imageData FROM file_migration_content WHERE fileId = ?",
            arguments: [id]
        ) }) {
            return ScreenshotContent(data: bytes, mimeType: file.contentType, variant: .original)
        }
        guard let reference = file.localReference ?? file.remoteReference else { throw ScreenshotContentError.unavailable }
        let source = try JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(reference.utf8))
        guard source.fileId == id, source.contentHash == file.contentHash,
              try await matchesCurrentSource(source, vaultId: file.vaultId, dbQueue: dbQueue) else {
            throw ScreenshotContentError.authorizationRequired
        }
        let content: ScreenshotContent
        if file.remoteReference == nil || file.localReference != nil && file.localReference != file.remoteReference {
            guard let original = try fileStore(for: dbQueue).read(source, variant: .original) else { throw ScreenshotContentError.unavailable }
            content = original
        } else {
            do {
                content = try await remoteContent(source, variant: variant, credentials: dbQueue)
            } catch where variant == .thumbnail {
                content = try await remoteContent(source, variant: .original, credentials: dbQueue)
            }
        }
        try Task.checkCancellation()
        let current = try await dbQueue.read { try FileRecord.fetchOne($0, key: id) }
        guard current?.localReference == file.localReference, current?.remoteReference == file.remoteReference,
              try await matchesCurrentSource(source, vaultId: file.vaultId, dbQueue: dbQueue) else { throw ScreenshotContentError.deleted }
        return content
    }

    private func matchesCurrentSource(_ source: ScreenshotRemoteReference, vaultId: UUID, dbQueue: DatabaseQueue) async throws -> Bool {
        try await dbQueue.read { db in
            guard let vault = try VaultRecord.fetchOne(db, key: vaultId),
                  vault.accountConnectionId == source.accountConnectionId else { return false }
            guard let connectionId = source.accountConnectionId else { return source.origin.isEmpty }
            return try DahliaAccountConnectionRecord.fetchOne(db, key: connectionId)?.origin == source.origin
        }
    }

    func resolved(_ record: MeetingScreenshotRecord, dbQueue: DatabaseQueue? = nil) async throws -> MeetingScreenshotRecord {
        if record.imageData != nil { return record }
        let content = try await content(id: record.id, dbQueue: dbQueue)
        var result = record
        result.imageData = content.data
        result.mimeType = content.mimeType
        return result
    }

    func resolved(_ records: [MeetingScreenshotRecord], dbQueue: DatabaseQueue? = nil) async throws -> [MeetingScreenshotRecord] {
        var result: [MeetingScreenshotRecord] = []
        for record in records {
            try Task.checkCancellation()
            try await result.append(resolved(record, dbQueue: dbQueue))
        }
        return result
    }

    nonisolated func retainOriginals(vaultIds: [UUID], dbQueue: DatabaseQueue) {
        retainedVaults.withLock { counts in
            for vaultId in vaultIds {
                counts[ObjectIdentifier(dbQueue), default: [:]][vaultId, default: 0] += 1
            }
        }
    }

    nonisolated func releaseOriginals(vaultIds: [UUID], dbQueue: DatabaseQueue) {
        let key = ObjectIdentifier(dbQueue)
        retainedVaults.withLock { counts in
            for vaultId in vaultIds {
                guard let count = counts[key]?[vaultId] else { continue }
                counts[key]?[vaultId] = count > 1 ? count - 1 : nil
            }
            if counts[key]?.isEmpty == true { counts[key] = nil }
        }
    }

    /// Only a matching configured origin may receive the account's credential.
    func remoteContent(
        _ source: ScreenshotRemoteReference,
        variant: ScreenshotVariant = .original,
        credentials: DatabaseQueue
    ) async throws -> ScreenshotContent {
        let files = try? fileStore(for: credentials)
        if let content = try? files?.read(source, variant: variant) { return content }
        if variant != .original, let content = try? files?.read(source, variant: .original) { return content }
        let connection = try await credentials.read { db in
            try DahliaAccountConnectionRecord.fetchOne(
                db,
                sql: "SELECT * FROM dahlia_account_connections WHERE id = ? AND origin = ?",
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
        let representation = variant == .original ? "content" : "variants/thumbnail"
        let url = origin.appending(path: "api/v1/files/\(source.fileId.uuidString.lowercased())/\(representation)")
        for attempt in 0 ... 1 {
            var request = URLRequest(url: url)
            let token = try await tokenProvider(connection.id, attempt == 1)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ScreenshotContentError.unavailable }
            if http.statusCode == 401, attempt == 0 { continue }
            if [401, 403].contains(http.statusCode) { throw ScreenshotContentError.authorizationRequired }
            if http.statusCode == 404 { throw ScreenshotContentError.deleted }
            guard http.statusCode == 200, response.expectedContentLength <= 64 * 1024 * 1024 else {
                throw ScreenshotContentError.unavailable
            }
            var bytes = Data()
            for try await byte in stream {
                guard bytes.count < 64 * 1024 * 1024 else { throw ScreenshotContentError.integrityFailure }
                bytes.append(byte)
            }
            let actual = http.value(forHTTPHeaderField: "x-dahlia-image-variant").flatMap(ScreenshotVariant.init(rawValue:)) ?? .original
            guard variant != .original || actual == .original,
                  actual != .original || ScreenshotRemoteReference.digest(bytes) == source.contentHash,
                  actual == .original || http.value(forHTTPHeaderField: "x-dahlia-original-sha256") == source.contentHash,
                  let mimeType = response.mimeType else {
                throw ScreenshotContentError.integrityFailure
            }
            let content = ScreenshotContent(data: bytes, mimeType: mimeType, variant: actual)
            try? files?.write(content, source: source)
            try? trimFiles(dbQueue: credentials)
            return content
        }
        throw ScreenshotContentError.authorizationRequired
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
