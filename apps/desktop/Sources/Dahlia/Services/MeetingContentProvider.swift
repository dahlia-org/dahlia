import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

/// Rebuildable text I/O. Recording and finalized persistence never call or wait for this actor.
actor MeetingContentProvider {
    static let shared = MeetingContentProvider()
    static let capacityBytes = 128 * 1024 * 1024

    struct Key: Hashable, Sendable {
        let database: ObjectIdentifier
        let entity: TextContentEntity
        let id: UUID
    }

    private struct Page: Decodable {
        struct Record: Decodable {
            let title: String?
            let document: String?
            let createdAt: Date?
            let ocrText: String?

            enum CodingKeys: String, CodingKey {
                case title, document, createdAt, caption
                case ocrText = "ocr_text"
            }

            let caption: String?
        }

        let version: Int
        let revision: Int
        let sha256: String
        let byteCount: Int
        let count: Int
        let record: Record?
        let items: [SyncTranscriptPage.Segment]?
        let nextCursor: String?
    }

    let client: SyncAPIClient
    struct Request {
        let id: UUID
        let task: Task<Void, Error>
        var users: Set<UUID>
        var background: Bool
    }

    var requests: [Key: Request] = [:]
    var leases: [Key: Int] = [:]
    var retainedVaults: [ObjectIdentifier: [UUID: Int]] = [:]
    var maintenance: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var activeReads = 0
    private var waiters: [(key: Key, background: Bool, continuation: CheckedContinuation<Void, Never>)] = []

    init(client: SyncAPIClient? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.client = client ?? SyncAPIClient(session: URLSession(configuration: configuration))
    }

    func retain(entity: TextContentEntity, id: UUID, dbQueue: DatabaseQueue) {
        leases[Key(database: ObjectIdentifier(dbQueue), entity: entity, id: id), default: 0] += 1
    }

    func release(entity: TextContentEntity, id: UUID, dbQueue: DatabaseQueue) {
        let key = Key(database: ObjectIdentifier(dbQueue), entity: entity, id: id)
        let count = leases[key, default: 0]
        leases[key] = count > 1 ? count - 1 : nil
    }

    func retainVault(_ vaultId: UUID, dbQueue: DatabaseQueue) {
        retainedVaults[ObjectIdentifier(dbQueue), default: [:]][vaultId, default: 0] += 1
    }

    func releaseVault(_ vaultId: UUID, dbQueue: DatabaseQueue) {
        let database = ObjectIdentifier(dbQueue)
        let count = retainedVaults[database]?[vaultId] ?? 0
        retainedVaults[database]?[vaultId] = count > 1 ? count - 1 : nil
    }

    func withContent<T: Sendable>(
        meetingId: UUID,
        entities: Set<TextContentEntity> = [.summary, .transcript],
        dbQueue: DatabaseQueue,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        for entity in entities {
            retain(entity: entity, id: meetingId, dbQueue: dbQueue)
        }
        defer { for entity in entities {
            release(entity: entity, id: meetingId, dbQueue: dbQueue)
        } }
        for entity in entities {
            try await ensure(entity: entity, id: meetingId, dbQueue: dbQueue)
        }
        return try await operation()
    }

    func withFileContent<T: Sendable>(
        id: UUID,
        dbQueue: DatabaseQueue,
        refresh: Bool = false,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        retain(entity: .file, id: id, dbQueue: dbQueue)
        defer { release(entity: .file, id: id, dbQueue: dbQueue) }
        try await ensure(entity: .file, id: id, dbQueue: dbQueue, refresh: refresh)
        return try await operation()
    }

    func ensure(entity: TextContentEntity, id: UUID, dbQueue: DatabaseQueue, refresh: Bool = false, prefetchBudget: Int? = nil) async throws {
        try Task.checkCancellation()
        let key = Key(database: ObjectIdentifier(dbQueue), entity: entity, id: id)
        let available = try await dbQueue.read { db in
            (try? TextContentAccess.requireComplete(entity: entity, id: id, in: db)) != nil
        }
        if available, !refresh {
            try await touch(entity: entity, id: id, dbQueue: dbQueue)
            return
        }
        let user = UUID()
        let request: Request
        if var existing = requests[key] {
            existing.users.insert(user)
            if prefetchBudget == nil { existing.background = false }
            requests[key] = existing
            request = existing
            if prefetchBudget == nil { prioritize(key) }
        } else {
            let requestId = UUID()
            let task = Task {
                defer { if self.requests[key]?.id == requestId { self.requests[key] = nil } }
                try await self.fetchReporting(entity: entity, id: id, dbQueue: dbQueue, prefetchBudget: prefetchBudget)
            }
            request = Request(id: requestId, task: task, users: [user], background: prefetchBudget != nil)
            requests[key] = request
        }
        try await withTaskCancellationHandler {
            try await request.task.value
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelRequest(key: key, requestId: request.id, user: user) }
        }
        // An explicit reader may have joined a budget-limited prefetch; retry without that limit.
        if prefetchBudget == nil,
           try await dbQueue.read({ (try? TextContentAccess.requireComplete(entity: entity, id: id, in: $0)) == nil }) {
            try await ensure(entity: entity, id: id, dbQueue: dbQueue, refresh: true)
        }
    }

    private func cancelRequest(key: Key, requestId: UUID, user: UUID) {
        guard var request = requests[key], request.id == requestId else { return }
        request.users.remove(user)
        requests[key] = request
        if request.users.isEmpty { request.task.cancel() }
    }

    private func fetchReporting(entity: TextContentEntity, id: UUID, dbQueue: DatabaseQueue, prefetchBudget: Int?) async throws {
        let expected = try await dbQueue.read { try TextContentStore.source(entity: entity, id: id, in: $0) }
        try await dbQueue.write { db in
            guard let expected, try TextContentStore.source(entity: entity, id: id, in: db) == expected else { return }
            try db.execute(
                sql: "UPDATE sync_content_state SET fetchError = 'loading' WHERE entity = ? AND entityId = ?",
                arguments: [entity.rawValue, id]
            )
        }
        do {
            try await fetch(entity: entity, id: id, dbQueue: dbQueue, prefetchBudget: prefetchBudget)
        } catch {
            let failure = error is CancellationError ? nil : (error as? TextContentError)?.rawValue ?? "unavailable"
            try? await dbQueue.write { db in
                guard let expected, let current = try TextContentStore.source(entity: entity, id: id, in: db),
                      current.vaultId == expected.vaultId, current.connectionId == expected.connectionId,
                      current.origin == expected.origin else { return }
                let message = current == expected ? failure : nil
                try db.execute(
                    sql: "UPDATE sync_content_state SET fetchError = ? WHERE entity = ? AND entityId = ? AND fetchError = 'loading'",
                    arguments: [message, entity.rawValue, id]
                )
            }
            throw error
        }
    }

    func touch(entity: TextContentEntity, id: UUID, dbQueue: DatabaseQueue) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sync_content_state SET lastAccessedAt = ? WHERE entity = ? AND entityId = ?",
                arguments: [Date(), entity.rawValue, id]
            )
        }
    }

    private func fetch(entity: TextContentEntity, id: UUID, dbQueue: DatabaseQueue, prefetchBudget: Int?) async throws {
        guard let source = try await dbQueue.read({ try TextContentStore.source(entity: entity, id: id, in: $0) }) else {
            throw TextContentError.unavailable
        }
        guard try await dbQueue.read({ try TextContentStore.mayFetch(source, entity: entity, id: id, in: $0) })
        else { throw TextContentError.changed }
        let key = Key(database: ObjectIdentifier(dbQueue), entity: entity, id: id)
        await acquire(key: key, background: requests[key]?.background ?? (prefetchBudget != nil))
        defer { releaseRead() }
        try Task.checkCancellation()
        let manifest = try await SyncJSON.decoder.decode(TextContentManifest.self, from: get(source: source, entity: entity, id: id, manifest: true))
        let expectedCount = manifest.count
        guard manifest.version == 1, manifest.entity == entity, manifest.entityId == id, manifest.revision == source.revision,
              manifest.byteCount >= 0, expectedCount >= 0 else { throw TextContentError.integrityFailure }
        if let prefetchBudget, manifest.byteCount > prefetchBudget {
            try await dbQueue.write { db in
                guard try TextContentStore.source(entity: entity, id: id, in: db) == source else { return }
                try db.execute(
                    sql: "UPDATE sync_content_state SET fetchError = NULL WHERE entity = ? AND entityId = ?",
                    arguments: [entity.rawValue, id]
                )
            }
            return
        }
        let verified = try await dbQueue.write { db in
            guard try TextContentStore.mayFetch(source, entity: entity, id: id, in: db) else { throw TextContentError.changed }
            let state = try TextContentAccess.availability(entity: entity, id: id, in: db)
            // The text hash excludes transcript headers, which metadata-only deltas do not carry.
            if entity != .transcript || state.revision == source.revision,
               let local = try TextContentStore.fingerprint(entity: entity, id: id, in: db),
               local.hash == manifest.sha256, local.bytes == manifest.byteCount, local.count == manifest.count {
                try TextContentStore.markVerified(manifest, source: source, accessed: prefetchBudget == nil, in: db)
                return true
            }
            if state.revision == source.revision, [.ready, .stale].contains(state.state) {
                throw TextContentError.integrityFailure
            }
            return false
        }
        if verified { return }
        if entity == .transcript {
            guard try await RemoteChangeApplier.beginTranscript(
                meetingId: id,
                vaultId: source.vaultId,
                expectedConnectionId: source.connectionId,
                dbQueue: dbQueue,
                incrementalContext: source.context
            ) else { throw TextContentError.changed }
        }
        defer {
            if entity == .transcript {
                try? dbQueue.write { try $0.execute(sql: "DELETE FROM sync_remote_transcript_items WHERE meetingId = ?", arguments: [id]) }
            }
        }
        let downloaded = try await downloadPages(source: source, entity: entity, id: id, manifest: manifest, dbQueue: dbQueue)
        try Task.checkCancellation()
        try await dbQueue.write { db in
            try Task.checkCancellation()
            guard try TextContentStore.mayFetch(source, entity: entity, id: id, in: db) else { throw TextContentError.changed }
            switch entity {
            case .transcript:
                try RemoteChangeApplier.installStagedTranscript(meetingId: id, in: db)
                try db.execute(sql: "DELETE FROM sync_remote_transcript_items WHERE meetingId = ?", arguments: [id])
            case .summary:
                if manifest.present {
                    guard let title = downloaded?.title, let document = downloaded?.document,
                          let date = downloaded?.createdAt else { throw TextContentError.integrityFailure }
                    try SummaryContent(meetingId: id, title: title, document: document, createdAt: date).save(db)
                } else {
                    try db.execute(sql: "DELETE FROM summaries WHERE meetingId = ?", arguments: [id])
                }
            case .file:
                try FileTextBodyRecord(fileId: id, ocrText: downloaded?.ocrText, caption: downloaded?.caption).save(db)
            }
            try TextContentStore.markVerified(manifest, source: source, accessed: prefetchBudget == nil, in: db)
        }
    }

    private func downloadPages(
        source: TextContentStore.Source,
        entity: TextContentEntity,
        id: UUID,
        manifest: TextContentManifest,
        dbQueue: DatabaseQueue
    ) async throws -> Page.Record? {
        var cursor: String?
        var digest = TextContentDigest()
        var count = 0
        var body: Page.Record?
        repeat {
            try Task.checkCancellation()
            let page = try await SyncJSON.decoder.decode(Page.self, from: get(source: source, entity: entity, id: id, cursor: cursor))
            guard page.version == 1, page.revision == source.revision else { throw TextContentError.changed }
            var pageDigest = TextContentDigest()
            if entity == .transcript {
                guard let items = page.items else { throw TextContentError.integrityFailure }
                for item in items {
                    guard item.isConfirmed else { throw TextContentError.integrityFailure }
                    let segmentId = item.segmentId.uuidString.lowercased()
                    pageDigest.add(segmentId, body: false)
                    digest.add(segmentId, body: false)
                    pageDigest.add(item.text)
                    digest.add(item.text)
                }
                guard items.count == page.count else { throw TextContentError.integrityFailure }
                count += items.count
                guard try await RemoteChangeApplier.applyTranscriptPage(
                    items,
                    meetingId: id,
                    vaultId: source.vaultId,
                    expectedConnectionId: source.connectionId,
                    dbQueue: dbQueue,
                    incrementalContext: source.context
                ) else { throw TextContentError.changed }
            } else {
                guard let record = page.record else { throw TextContentError.integrityFailure }
                body = record
                let fields: [String?] = entity == .summary ? [record.document] : [record.ocrText, record.caption]
                for value in fields {
                    pageDigest.add(value)
                    digest.add(value)
                }
                count = page.count
            }
            let pageCount = page.count
            guard pageDigest.digestHex() == page.sha256, pageDigest.byteCount == page.byteCount,
                  page.nextCursor == nil || (entity == .transcript && page.nextCursor != cursor && pageCount > 0) else {
                throw TextContentError.integrityFailure
            }
            cursor = page.nextCursor
        } while cursor != nil
        guard digest.digestHex() == manifest.sha256, digest.byteCount == manifest.byteCount, count == manifest.count else {
            throw TextContentError.integrityFailure
        }
        return body
    }

    private func get(
        source: TextContentStore.Source,
        entity: TextContentEntity,
        id: UUID,
        manifest: Bool = false,
        cursor: String? = nil
    ) async throws -> Data {
        guard var url = URLComponents(string: source.origin) else { throw URLError(.badURL) }
        url.path = "/api/v1/vaults/\(source.vaultId.uuidString.lowercased())/text/\(entity.rawValue)/\(id.uuidString.lowercased())"
        url.queryItems = [URLQueryItem(name: "revision", value: String(source.revision))]
        if manifest { url.queryItems?.append(URLQueryItem(name: "manifest", value: "1")) }
        if let cursor { url.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        guard let address = url.url else { throw URLError(.badURL) }
        do {
            // A single accepted 8 MiB transcript chunk needs room for the read response envelope.
            return try await client.data(for: URLRequest(url: address), connectionId: source.connectionId, maximumBytes: 9 * 1024 * 1024)
        } catch let error as SyncHTTPError {
            switch error.status {
            case 401, 403: throw TextContentError.authorizationRequired
            case 404: throw error.code?.hasSuffix("_not_found") == true ? TextContentError.deleted : .updateRequired
            case 409: throw TextContentError.changed
            case 426: throw TextContentError.updateRequired
            default: throw TextContentError.unavailable
            }
        }
    }

    private func acquire(key: Key, background: Bool) async {
        if activeReads < (background ? 1 : 2) { activeReads += 1
            return
        }
        await withCheckedContinuation { waiters.append((key, background, $0)) }
    }

    private func prioritize(_ key: Key) {
        guard let index = waiters.firstIndex(where: { $0.key == key }) else { return }
        waiters[index].background = false
        if activeReads < 2 {
            activeReads += 1
            waiters.remove(at: index).continuation.resume()
        }
    }

    private func releaseRead() {
        activeReads -= 1
        if let index = waiters.firstIndex(where: { !$0.background }) ?? (activeReads == 0 ? waiters.indices.first : nil) {
            activeReads += 1
            waiters.remove(at: index).continuation.resume()
        }
    }
}
