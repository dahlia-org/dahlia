import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB
import Synchronization

/// Owns optional image retrieval. Durable capture and canonical metadata never wait on this service.
actor ScreenshotContentProvider {
    static let shared = ScreenshotContentProvider()

    private var database: DatabaseQueue?
    private var cache: ScreenshotDiskCache?
    private let session: URLSession
    private let tokenProvider: @Sendable (UUID, Bool) async throws -> String
    private var activeReads = 0
    private var activeThumbnails = 0
    private var waiters: [(id: UUID, variant: ScreenshotVariant, continuation: CheckedContinuation<Bool, Never>)] = []
    private nonisolated let retainedVaults = Mutex<[ObjectIdentifier: [UUID: Int]]>([:])

    init(
        session: URLSession? = nil,
        cache: ScreenshotDiskCache? = nil,
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

    func configure(dbQueue: DatabaseQueue) {
        database = dbQueue
        if cache == nil { cache = try? ScreenshotDiskCache() }
    }

    func trimCache() {
        try? cache?.trim()
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
        if let data = record.imageData {
            return ScreenshotContent(data: data, mimeType: record.mimeType, variant: .original)
        }
        guard let source = record.remoteSource else { throw ScreenshotContentError.unavailable }
        guard try await matchesCurrentSource(source, id: id, dbQueue: dbQueue) else {
            throw ScreenshotContentError.authorizationRequired
        }
        let content = try await remoteContent(source, variant: variant, credentials: dbQueue)
        try Task.checkCancellation()
        let current = try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT remoteReference FROM screenshots WHERE id = ?", arguments: [id])
        }
        guard current == record.remoteReference,
              try await matchesCurrentSource(source, id: id, dbQueue: dbQueue) else { throw ScreenshotContentError.deleted }
        return content
    }

    private func matchesCurrentSource(_ source: ScreenshotRemoteReference, id: UUID, dbQueue: DatabaseQueue) async throws -> Bool {
        guard source.screenshotId == id else { return false }
        return try await dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM screenshots s JOIN meetings m ON m.id = s.meetingId
            JOIN vaults v ON v.id = m.vaultId JOIN dahlia_account_connections c ON c.id = v.accountConnectionId
            WHERE s.id = ? AND m.id = ? AND v.id = ? AND c.origin = ?)
            """, arguments: [id, source.meetingId, source.vaultId, source.origin]) ?? false
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

    func hydrateOriginals(
        vaultId: UUID,
        dbQueue: DatabaseQueue,
        credentials: DatabaseQueue? = nil,
        screenshotIds: [UUID]? = nil
    ) async throws {
        if let screenshotIds, screenshotIds.isEmpty { return }
        while true {
            try Task.checkCancellation()
            let record = try await dbQueue.read { db in
                var request = MeetingScreenshotRecord
                    .filter(sql: "meetingId IN (SELECT id FROM meetings WHERE vaultId = ?)", arguments: [vaultId])
                    .filter(Column("imageData") == nil)
                if let screenshotIds { request = request.filter(screenshotIds.contains(Column("id"))) }
                return try request.order(Column("id")).fetchOne(db)
            }
            guard let record else { return }
            guard let source = record.remoteSource else { throw ScreenshotContentError.unavailable }
            let content = try await remoteContent(source, credentials: credentials ?? dbQueue)
            try await dbQueue.write { db in
                try db.execute(sql: """
                UPDATE screenshots SET imageData = ?, mimeType = ?, contentLength = ?
                WHERE id = ? AND imageData IS NULL AND remoteReference = ?
                  AND meetingId IN (SELECT id FROM meetings WHERE vaultId = ?)
                """, arguments: [content.data, content.mimeType, content.data.count, record.id, record.remoteReference, vaultId])
            }
        }
    }

    /// Eviction is a projection change. Recheck durability and recording state in the same write.
    func evictConfirmedOriginals(dbQueue: DatabaseQueue, limit: Int = 16) async throws {
        for _ in 0 ..< limit {
            try Task.checkCancellation()
            let record = try await dbQueue.read { db in
                let retained = self.retainedVaults.withLock { $0[ObjectIdentifier(dbQueue)]?.keys.map(\.self) ?? [] }
                let exclusion = retained.isEmpty ? "" : "AND v.id NOT IN (\(retained.map { _ in "?" }.joined(separator: ",")))"
                return try MeetingScreenshotRecord.fetchOne(db, sql: """
                SELECT s.* FROM screenshots s JOIN meetings m ON m.id = s.meetingId
                JOIN vaults v ON v.id = m.vaultId
                JOIN sync_entity_state e ON e.vaultId = v.id AND e.entity = 'screenshot' AND e.entityId = s.id
                WHERE s.imageData IS NOT NULL AND s.remoteReference IS NOT NULL AND s.contentHash IS NOT NULL
                  AND e.confirmedRevision > 0 AND v.accountConnectionId = v.syncConfirmedConnectionId
                  AND v.syncPullCursor IS NOT NULL AND v.syncRecoveryState IS NULL
                  AND NOT EXISTS (SELECT 1 FROM sync_transactions t WHERE t.vaultId = v.id)
                  AND NOT EXISTS (SELECT 1 FROM recording_sessions WHERE endedAt IS NULL)
                  \(exclusion)
                ORDER BY s.capturedAt LIMIT 1
                """, arguments: StatementArguments(retained))
            }
            guard let record, let source = record.remoteSource, let bytes = record.imageData,
                  source.contentHash == record.contentHash,
                  ScreenshotRemoteReference.digest(bytes) == source.contentHash else { return }
            try? cache?.write(ScreenshotContent(data: bytes, mimeType: record.mimeType, variant: .original), source: source)
            try await dbQueue.write { db in
                // A retention request can arrive after candidate selection. Earlier writes finish
                // before hydration reads on this queue, so an already-running eviction is refilled.
                guard self.retainedVaults.withLock({ $0[ObjectIdentifier(dbQueue)]?[source.vaultId] == nil }) else { return }
                try db.execute(sql: """
                UPDATE screenshots SET imageData = NULL WHERE id = ? AND remoteReference = ? AND contentHash = ?
                  AND EXISTS (
                    SELECT 1 FROM meetings m JOIN vaults v ON v.id = m.vaultId
                    JOIN dahlia_account_connections c ON c.id = v.accountConnectionId
                    JOIN sync_entity_state e ON e.vaultId = v.id AND e.entity = 'screenshot' AND e.entityId = screenshots.id
                    WHERE m.id = screenshots.meetingId AND v.id = ? AND c.origin = ?
                      AND e.confirmedRevision > 0 AND v.accountConnectionId = v.syncConfirmedConnectionId
                      AND v.syncPullCursor IS NOT NULL AND v.syncRecoveryState IS NULL
                      AND NOT EXISTS (SELECT 1 FROM sync_transactions t WHERE t.vaultId = v.id)
                  )
                  AND NOT EXISTS (SELECT 1 FROM recording_sessions WHERE endedAt IS NULL)
                """, arguments: [record.id, record.remoteReference, record.contentHash, source.vaultId, source.origin])
            }
        }
    }

    /// Restore may reference original server IDs after local IDs have been remapped.
    /// Only a matching configured origin may receive the account's credential.
    func remoteContent(
        _ source: ScreenshotRemoteReference,
        variant: ScreenshotVariant = .original,
        credentials: DatabaseQueue
    ) async throws -> ScreenshotContent {
        if let content = try? cache?.read(source, variant: variant) { return content }
        if variant != .original, let content = try? cache?.read(source, variant: .original) { return content }
        let connection = try await credentials.read { db in
            try DahliaAccountConnectionRecord.fetchOne(
                db,
                sql: "SELECT * FROM dahlia_account_connections WHERE origin = ?",
                arguments: [source.origin]
            )
        }
        guard let connection, let origin = URL(string: connection.origin),
              source.contentHash.count == 64, source.contentHash.allSatisfy(\.isHexDigit) else {
            throw ScreenshotContentError.authorizationRequired
        }
        try await acquireRead(variant: variant)
        defer { releaseRead(variant: variant) }
        try Task.checkCancellation()
        let path = "api/v1/vaults/\(source.vaultId.uuidString.lowercased())/meetings/\(source.meetingId.uuidString.lowercased())/screenshots/\(source.screenshotId.uuidString.lowercased())/content"
        var components = URLComponents(url: origin.appending(path: path), resolvingAgainstBaseURL: false)!
        if variant == .thumbnail { components.queryItems = [URLQueryItem(name: "variant", value: "thumbnail")] }
        for attempt in 0 ... 1 {
            var request = URLRequest(url: components.url!)
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
                  let mimeType = response.mimeType, ["image/png", "image/jpeg", "image/webp", "image/gif", "image/tiff"].contains(mimeType) else {
                throw ScreenshotContentError.integrityFailure
            }
            let content = ScreenshotContent(data: bytes, mimeType: mimeType, variant: actual)
            try? cache?.write(content, source: source)
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
