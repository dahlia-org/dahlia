import CryptoKit
import DahliaRuntimeSupport
import Foundation
import GRDB
import Synchronization

struct SyncOperationBody: Encodable {
    let id: UUID
    let entity: SyncEntity
    let action: SyncAction
    let entityId: UUID
    let baseRevision: Int?
    let data: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case id
        case entity
        case action
        case entityId
        case baseRevision
        case data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(entity, forKey: .entity)
        try container.encode(action, forKey: .action)
        try container.encode(entityId, forKey: .entityId)
        if let baseRevision {
            try container.encode(baseRevision, forKey: .baseRevision)
        } else {
            try container.encodeNil(forKey: .baseRevision)
        }
        if let data {
            try container.encode(data, forKey: .data)
        } else {
            try container.encodeNil(forKey: .data)
        }
    }
}

private struct FileUploadResponse: Decodable {
    let id: UUID
    let vaultId: UUID
    let size: Int
    let checksum: String
}

private struct SyncTransactionResolution: Decodable {
    let id: UUID
    let status: String
}

private struct SyncTransactionBody: Encodable {
    let schemaVersion = 2
    let id: UUID
    let vaultId: UUID
    let createdAt: Date
    let operations: [SyncOperationBody]
}

struct TranscriptChunkBody: Codable {
    struct Segment: Codable {
        let segmentId: UUID
        let startTime: Date
        let endTime: Date?
        let text: String
        let isConfirmed: Bool
        let audioSource: String?
        let speakerLabel: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(segmentId, forKey: .segmentId)
            try container.encode(startTime, forKey: .startTime)
            try container.encode(endTime, forKey: .endTime)
            try container.encode(text, forKey: .text)
            try container.encode(isConfirmed, forKey: .isConfirmed)
            try container.encode(audioSource, forKey: .audioSource)
            try container.encode(speakerLabel, forKey: .speakerLabel)
        }
    }

    let segments: [Segment]
    let deletions: [UUID]
}

private struct TranscriptPatchData: Codable {
    struct Chunk: Codable {
        let index: Int
        let sha256: String
        let segmentCount: Int
        let deletionCount: Int
    }

    let patchId: UUID
    let segmentCount: Int
    let deletionCount: Int
    let chunks: [Chunk]
}

struct SyncChangePage: Decodable {
    struct Change: Codable, Sendable {
        let sequence: Int
        let entity: SyncEntity
        let entityId: UUID
        let action: String
        let revision: Int?
        let record: SyncCanonicalPayload?
    }

    let items: [Change]
    let cursor: String
    let highWaterCursor: String
    let hasMore: Bool
}

struct SyncResetSnapshot {
    let projects: Set<UUID>
    let meetings: Set<UUID>
    let summaries: Set<UUID>
    let transcripts: Set<UUID>
    let screenshots: Set<UUID>
    let files: Set<UUID>
    let recordings: Set<UUID>

    init(ids: [SyncEntity: Set<UUID>]) {
        projects = ids[.project, default: []]
        meetings = ids[.meeting, default: []]
        summaries = ids[.summary, default: []]
        transcripts = ids[.transcript, default: []]
        screenshots = ids[.meetingFile, default: []]
        files = ids[.file, default: []]
        recordings = ids[.recording, default: []]
    }

    init?(_ changes: [SyncChangePage.Change]) {
        guard changes.contains(where: { $0.entity == .vault && $0.action == "reset" && $0.record != nil }) else {
            return nil
        }
        self.init(canonicalChanges: changes)
    }

    init(canonicalChanges changes: [SyncChangePage.Change]) {
        func ids(_ entity: SyncEntity) -> Set<UUID> {
            Set(changes.lazy.filter { $0.entity == entity && $0.action == "upsert" && $0.record != nil }.map(\.entityId))
        }
        projects = ids(.project)
        meetings = ids(.meeting)
        summaries = ids(.summary)
        transcripts = ids(.transcript)
        screenshots = ids(.meetingFile)
        files = ids(.file)
        recordings = ids(.recording)
    }
}

struct SyncProjectSnapshot: Decodable, Sendable {
    let projectId: UUID
    let parentProjectId: UUID?
    let name: String
    let description: String
    let projectType: String?
    let revision: Int
    let createdAt: Date
}

private struct SyncProjectSnapshotPage: Decodable {
    let items: [SyncProjectSnapshot]
}

private struct SyncMeetingSnapshotHeader: Decodable {
    let meetingId: UUID
    let revision: Int
}

struct SyncTranscriptPage: Decodable {
    struct Segment: Decodable {
        let segmentId: UUID
        let startTime: Date
        let endTime: Date?
        let text: String
        let isConfirmed: Bool
        let audioSource: String?
        let speakerLabel: String?
    }

    let items: [Segment]
    let nextCursor: String?
}

private struct SyncTarget: Sendable {
    let vaultId: UUID
    let connectionId: UUID
    let origin: URL
    let cursor: String?
    let mutationGeneration: Int64

    var context: RemoteChangePolicy.Context {
        .init(vaultId: vaultId, connectionId: connectionId, generation: mutationGeneration)
    }
}

actor SyncWorker {
    private static let transcriptChunkSize = 500
    private static let transcriptChunkMaximumBytes = 6 * 1024 * 1024
    private static let transcriptPatchItemLimit = 50000
    private static let transcriptPatchMaximumChunks = 100

    private let dbQueue: DatabaseQueue
    private let session: URLSession
    private let archiveService: RecordingArchiveService
    private let apiClient: SyncAPIClient
    private let vaultsDidChange: @MainActor @Sendable () async -> Void
    private var drainTask: Task<Void, Never>?
    private var eventTasks: [UUID: Task<Void, Never>] = [:]
    private var isPulling = false
    private struct PullKey: Hashable { let database: ObjectIdentifier
        let vaultId: UUID
    }

    /// Transfer checks create another worker; serialize only reads of the same Vault in the same database.
    private static let pullingVaults = Mutex<Set<PullKey>>([])

    init(
        dbQueue: DatabaseQueue,
        session: URLSession = .shared,
        apiClient: SyncAPIClient? = nil,
        vaultsDidChange: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.dbQueue = dbQueue
        self.session = session
        self.apiClient = apiClient ?? SyncAPIClient(session: session)
        archiveService = RecordingArchiveService(dbQueue: dbQueue, api: apiClient ?? SyncAPIClient(session: session))
        self.vaultsDidChange = vaultsDidChange
    }

    func start() async {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await retryAuthorizationBlocks()
                await restartEventStreams()
                try await pullRemoteChanges()
            } catch {
                ErrorReportingService.capture(error, context: ["source": "syncStart"])
            }
            await runDrain()
            await clearDrainTask()
        }
    }

    func applicationBecameActive() async {
        do {
            try await pullRemoteChanges()
        } catch {
            ErrorReportingService.capture(error, context: ["source": "syncResume"])
        }
        await restartEventStreams()
        drain()
    }

    func stop() async {
        drainTask?.cancel()
        await drainTask?.value
        drainTask = nil
        for task in eventTasks.values {
            task.cancel()
        }
        for task in eventTasks.values {
            await task.value
        }
        eventTasks.removeAll()
    }

    func drain() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.runDrain()
            await self?.clearDrainTask()
        }
    }

    private func clearDrainTask() {
        drainTask = nil
    }

    private func retryAuthorizationBlocks() async throws {
        let connectionIds = try await dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT DISTINCT connectionId FROM sync_transactions WHERE blockedReason = 'authorization'"
            )
        }
        for connectionId in connectionIds {
            try await SyncTransactionQueue.retryAuthorizationBlocks(connectionId: connectionId, dbQueue: dbQueue)
        }
    }

    private func runDrain() async {
        var nextPull = ContinuousClock.now
        while !Task.isCancelled {
            do {
                if ContinuousClock.now >= nextPull {
                    try await pullRemoteChanges()
                    nextPull = .now.advanced(by: .seconds(5))
                }
                try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: dbQueue) { error in
                    ErrorReportingService.capture(error, context: ["source": "syncDrain"])
                }
                guard let transaction = try await SyncTransactionQueue.claim(dbQueue: dbQueue) else {
                    try await archiveService.runNext()
                    try? await ScreenshotContentProvider.shared.trimFiles(dbQueue: dbQueue)
                    try? await ScreenshotStorageMaintenance.reclaimIncrementally(dbQueue: dbQueue)
                    try await Task.sleep(for: .seconds(5))
                    continue
                }
                do {
                    try await ScreenshotContentProvider.shared.migrateLegacyImages(vaultId: transaction.vaultId, dbQueue: dbQueue)
                    if let response = try await push(transaction) {
                        try await SyncTransactionQueue.complete(transaction, response: response, dbQueue: dbQueue)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as SyncHTTPError {
                    if error.status == 410, error.code == "meeting_event_parent_unavailable",
                       transaction.operations.allSatisfy({ $0.entity == .meetingEvent }) {
                        // A deleted meeting must not be recreated just to upload diagnostic history.
                        try await dbQueue.write { db in
                            guard try SyncTransactionQueue.matchesExpectedConnection(
                                vaultId: transaction.vaultId, connectionId: transaction.connectionId, in: db
                            ) else { return }
                            try db.execute(sql: "DELETE FROM sync_transactions WHERE id = ?", arguments: [transaction.id])
                        }
                        continue
                    }
                    if error.status == 426 {
                        try await dbQueue.write { db in
                            guard try SyncTransactionQueue.matchesExpectedConnection(
                                vaultId: transaction.vaultId, connectionId: transaction.connectionId, in: db
                            ) else { return }
                            try db.execute(
                                sql: "UPDATE vaults SET syncRecoveryState = 'updateRequired' WHERE id = ?",
                                arguments: [transaction.vaultId]
                            )
                        }
                    }
                    if let reason = error.blockedReason {
                        try await SyncTransactionQueue.block(
                            transaction,
                            reason: reason,
                            response: error.body,
                            dbQueue: dbQueue
                        )
                    } else {
                        try await SyncTransactionQueue.retry(
                            transaction,
                            code: "http_\(error.status)",
                            dbQueue: dbQueue
                        )
                    }
                } catch {
                    try await SyncTransactionQueue.retry(
                        transaction,
                        code: error is URLError ? "network" : "sync_failed",
                        dbQueue: dbQueue
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                ErrorReportingService.capture(error, context: ["source": "syncDrain"])
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func push(_ transaction: SyncQueuedTransaction) async throws -> SyncTransactionResponse? {
        guard let target = try await connection(id: transaction.connectionId) else {
            throw SyncHTTPError(status: 403, body: Data("{\"error\":\"connection_missing\"}".utf8))
        }
        if transaction.operations.allSatisfy({ $0.entity == .meetingEvent }) {
            let data = try await sendData(
                request(origin: target, path: "api/v1/capabilities", method: "GET"),
                connectionId: transaction.connectionId
            )
            let capabilities = try decode(ServerCapabilities.self, from: data)
            if capabilities.meetingEvents?.version != 1 {
                // A downgraded Server must not block unrelated durable content behind unsupported diagnostics.
                try await dbQueue.write { db in
                    guard try SyncTransactionQueue.matchesExpectedConnection(
                        vaultId: transaction.vaultId, connectionId: transaction.connectionId, in: db
                    ) else { return }
                    try db.execute(sql: "UPDATE vaults SET syncMeetingEventsVersion = 0 WHERE id = ?", arguments: [transaction.vaultId])
                    try db.execute(sql: "DELETE FROM sync_transactions WHERE id = ?", arguments: [transaction.id])
                }
                return nil
            }
        }
        let body = try await transactionBody(transaction, origin: target, stageAttachments: false)
        let resolved = try await sendData(
            request(origin: target, path: "api/v1/transactions/resolve", method: "POST", body: body, contentType: "application/json"),
            connectionId: transaction.connectionId
        )
        let resolution = try SyncJSON.decoder.decode(SyncTransactionResolution.self, from: resolved)
        guard resolution.id == transaction.id else { throw SyncTransactionQueueError.invalidReceipt }
        if resolution.status == "committed" {
            return try SyncJSON.decoder.decode(SyncTransactionResponse.self, from: resolved)
        }
        guard resolution.status == "unknown" else { throw SyncTransactionQueueError.invalidReceipt }
        let stagedBody = try await transactionBody(transaction, origin: target, stageAttachments: true)
        guard stagedBody == body else { throw SyncTransactionQueueError.invalidReceipt }
        let data = try await sendData(
            request(origin: target, path: "api/v1/transactions", method: "POST", body: body, contentType: "application/json"),
            connectionId: transaction.connectionId
        )
        return try SyncJSON.decoder.decode(SyncTransactionResponse.self, from: data)
    }

    private func transactionBody(
        _ transaction: SyncQueuedTransaction,
        origin target: URL,
        stageAttachments: Bool
    ) async throws -> Data {
        var operations = transaction.operations
        for index in operations.indices {
            let operation = operations[index]
            if stageAttachments, operation.entity == .file,
               operation.action != .delete,
               let attachment = try await SyncTransactionQueue.screenshotAttachment(
                   operationId: operation.id,
                   dbQueue: dbQueue
               ) {
                let payload = try decode(FileOperationPayload.self, from: operation.payloadJSON)
                var components = URLComponents()
                components.path = "api/v1/files"
                components.queryItems = [
                    URLQueryItem(name: "id", value: operation.entityId.lowercase),
                    URLQueryItem(name: "vaultId", value: transaction.vaultId.lowercase),
                    URLQueryItem(name: "name", value: payload.name),
                    URLQueryItem(name: "source", value: payload.metadata.source.rawValue),
                ]
                if let width = payload.metadata.width {
                    components.queryItems?.append(URLQueryItem(name: "width", value: String(width)))
                }
                if let height = payload.metadata.height {
                    components.queryItems?.append(URLQueryItem(name: "height", value: String(height)))
                }
                // URL query parsers treat a literal plus as a space.
                guard let path = components.string?.replacingOccurrences(of: "+", with: "%2B") else { throw URLError(.badURL) }
                let data = try await sendData(request(
                    origin: target,
                    path: path,
                    method: "POST",
                    body: attachment.bytes,
                    contentType: attachment.mimeType
                ), connectionId: transaction.connectionId)
                let uploaded = try SyncJSON.decoder.decode(FileUploadResponse.self, from: data)
                guard uploaded.id == operation.entityId, uploaded.vaultId == transaction.vaultId,
                      uploaded.size == attachment.bytes.count,
                      uploaded.checksum == "SHA-256:" + attachment.sha256,
                      uploaded.checksum == payload.checksum else { throw SyncTransactionQueueError.invalidReceipt }
            } else if stageAttachments, operation.entity == .recording, operation.action == .upsert, let payload = operation.payloadJSON {
                try await archiveService.stage(
                    sessionId: operation.entityId,
                    payload: payload,
                    origin: target,
                    connectionId: transaction.connectionId
                )
            } else if operation.entity == .transcript, operation.action == .patch {
                let payload = try await stageTranscriptPatch(operation, transaction: transaction, origin: target, sendUploads: stageAttachments)
                operations[index] = SyncQueuedOperation(
                    id: operation.id,
                    entity: operation.entity,
                    action: operation.action,
                    entityId: operation.entityId,
                    baseRevision: operation.baseRevision,
                    payloadJSON: payload
                )
            }
        }

        return try SyncJSON.encoder.encode(SyncTransactionBody(
            id: transaction.id,
            vaultId: transaction.vaultId,
            createdAt: transaction.createdAt,
            operations: operations.map { operation in
                try SyncOperationBody(
                    id: operation.id,
                    entity: operation.entity,
                    action: operation.action,
                    entityId: operation.entityId,
                    baseRevision: operation.baseRevision,
                    data: operation.payloadJSON.map { try SyncJSON.decoder.decode(JSONValue.self, from: $0) }
                )
            }
        ))
    }

    private func stageTranscriptPatch(
        _ operation: SyncQueuedOperation,
        transaction: SyncQueuedTransaction,
        origin: URL,
        sendUploads: Bool
    ) async throws -> Data {
        let snapshot = try await SyncTransactionQueue.transcriptPatch(operationId: operation.id, dbQueue: dbQueue)
        let transcriptChunks = try Self.transcriptChunks(snapshot)
        guard snapshot.segments.count <= Self.transcriptPatchItemLimit,
              snapshot.deletions.count <= Self.transcriptPatchItemLimit,
              transcriptChunks.count <= Self.transcriptPatchMaximumChunks else {
            throw SyncHTTPError(status: 422, body: Data("{\"error\":\"transcript_patch_too_large\"}".utf8))
        }
        var chunks: [TranscriptPatchData.Chunk] = []
        for (index, chunk) in transcriptChunks.enumerated() {
            let body = chunk.body
            let data = chunk.data
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if sendUploads {
                var upload = try request(
                    origin: origin,
                    path: "api/v1/vaults/\(transaction.vaultId.lowercase)/meetings/\(operation.entityId.lowercase)/transcripts/\(operation.id.lowercase)/chunks/\(index)",
                    method: "PUT",
                    body: data,
                    contentType: "application/json"
                )
                upload.setValue(hash, forHTTPHeaderField: "X-Dahlia-Content-SHA256")
                try await send(upload, connectionId: transaction.connectionId)
            }
            chunks.append(.init(
                index: index,
                sha256: hash,
                segmentCount: body.segments.count,
                deletionCount: body.deletions.count
            ))
        }
        return try SyncJSON.encoder.encode(TranscriptPatchData(
            patchId: operation.id,
            segmentCount: snapshot.segments.count,
            deletionCount: snapshot.deletions.count,
            chunks: chunks
        ))
    }

    static func transcriptChunks(
        _ snapshot: SyncTranscriptPatchSnapshot
    ) throws -> [(body: TranscriptChunkBody, data: Data)] {
        let segments = snapshot.segments.map {
            TranscriptChunkBody.Segment(
                segmentId: $0.segmentId,
                startTime: $0.startTime,
                endTime: $0.endTime,
                text: $0.text,
                isConfirmed: $0.isConfirmed,
                audioSource: $0.audioSource,
                speakerLabel: $0.speakerLabel
            )
        }
        var segmentOffset = 0
        var deletionOffset = 0
        var chunks: [(body: TranscriptChunkBody, data: Data)] = []
        repeat {
            let segmentEnd = min(segmentOffset + transcriptChunkSize, segments.count)
            let deletionEnd = min(deletionOffset + transcriptChunkSize, snapshot.deletions.count)
            let combined = TranscriptChunkBody(
                segments: Array(segments[segmentOffset ..< segmentEnd]),
                deletions: Array(snapshot.deletions[deletionOffset ..< deletionEnd])
            )
            let combinedData = try SyncJSON.encoder.encode(combined)
            if combinedData.count <= transcriptChunkMaximumBytes {
                chunks.append((combined, combinedData))
                segmentOffset = segmentEnd
                deletionOffset = deletionEnd
                continue
            }

            if segmentOffset < segmentEnd {
                let chunk = try largestTranscriptChunk(maximumCount: segmentEnd - segmentOffset) { count in
                    TranscriptChunkBody(
                        segments: Array(segments[segmentOffset ..< segmentOffset + count]),
                        deletions: []
                    )
                }
                chunks.append(chunk)
                segmentOffset += chunk.body.segments.count
            } else {
                let chunk = try largestTranscriptChunk(maximumCount: deletionEnd - deletionOffset) { count in
                    TranscriptChunkBody(
                        segments: [],
                        deletions: Array(snapshot.deletions[deletionOffset ..< deletionOffset + count])
                    )
                }
                chunks.append(chunk)
                deletionOffset += chunk.body.deletions.count
            }
        } while segmentOffset < segments.count || deletionOffset < snapshot.deletions.count || chunks.isEmpty
        return chunks
    }

    private static func largestTranscriptChunk(
        maximumCount: Int,
        body: (Int) -> TranscriptChunkBody
    ) throws -> (body: TranscriptChunkBody, data: Data) {
        var lower = 1
        var upper = maximumCount
        var result: (body: TranscriptChunkBody, data: Data)?
        while lower <= upper {
            let count = (lower + upper) / 2
            let candidate = body(count)
            let data = try SyncJSON.encoder.encode(candidate)
            if data.count <= transcriptChunkMaximumBytes {
                result = (candidate, data)
                lower = count + 1
            } else {
                upper = count - 1
            }
        }
        guard let result else { throw SyncTransactionQueueError.invalidReceipt }
        return result
    }

    func pullRemoteChanges(vaultId: UUID, connectionId: UUID) async throws -> Bool {
        guard let target = try await pullTargets().first(where: { $0.vaultId == vaultId && $0.connectionId == connectionId }) else {
            throw TextContentError.changed
        }
        return try await pullRemoteChanges(for: target)
    }

    func synchronizeForTransfer(vaultId: UUID, connectionId: UUID) async throws {
        guard try await pullRemoteChanges(vaultId: vaultId, connectionId: connectionId) else { throw TextContentError.changed }
        guard try await dbQueue.read({ db in
            try SyncTransactionQueue.matchesExpectedConnection(vaultId: vaultId, connectionId: connectionId, in: db)
                && !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db)
                && String
                .fetchOne(db, sql: "SELECT syncPullCursor FROM vaults WHERE id = ? AND syncRecoveryState IS NULL", arguments: [vaultId]) != nil
        }) else { throw TextContentError.changed }
    }

    func validateTransferCursor(vaultId: UUID, connectionId: UUID, cursor: String) async throws {
        guard let target = try await pullTargets().first(where: { $0.vaultId == vaultId && $0.connectionId == connectionId }),
              target.cursor == cursor else { throw TextContentError.changed }
        // Do not pin the old high-water mark: observe changes committed during text/image hydration.
        let page = try await loadChangePage(target: target, cursor: cursor, highWaterCursor: nil)
        guard page.highWaterCursor == cursor, page.cursor == cursor, page.items.isEmpty, !page.hasMore else {
            throw TextContentError.changed
        }
    }

    private func pullRemoteChanges() async throws {
        guard !isPulling else { return }
        isPulling = true
        defer { isPulling = false }
        for target in try await pullTargets() {
            do {
                try await ScreenshotContentProvider.shared.migrateLegacyImages(vaultId: target.vaultId, dbQueue: dbQueue)
                _ = try await pullRemoteChanges(for: target)
                await MeetingContentProvider.shared.scheduleMaintenance(dbQueue: dbQueue)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SyncHTTPError where error.status == 426 {
                try? await setRecoveryState("updateRequired", target: target)
            } catch let error as SyncHTTPError where error.status == 410 && error.code == "sync_cursor_expired" {
                try? await recoverSnapshot(target)
            } catch let error as SyncHTTPError where error.status == 404 && error.code == "vault_not_found" {
                if try await RemoteChangeApplier.reconcileMissingVault(
                    vaultId: target.vaultId,
                    expectedConnectionId: target.connectionId,
                    dbQueue: dbQueue,
                    expectedMutationGeneration: target.mutationGeneration
                ) {
                    await vaultsDidChange()
                }
            } catch {
                continue
            }
        }
    }

    private func pullRemoteChanges(for target: SyncTarget) async throws -> Bool {
        let key = PullKey(database: ObjectIdentifier(dbQueue), vaultId: target.vaultId)
        guard Self.pullingVaults.withLock({ $0.insert(key).inserted }) else { throw TextContentError.changed }
        defer { _ = Self.pullingVaults.withLock { $0.remove(key) } }
        do {
            let data = try await sendData(
                request(origin: target.origin, path: "api/v1/capabilities", method: "GET"),
                connectionId: target.connectionId
            )
            let capabilities = try decode(ServerCapabilities.self, from: data)
            guard capabilities.sync?.version == 3 else {
                throw SyncHTTPError(status: 426, body: Data())
            }
            let meetingEventsVersion = capabilities.meetingEvents?.version == 1 ? 1 : 0
            try await dbQueue.write { db in
                guard try SyncTransactionQueue.matchesExpectedConnection(
                    vaultId: target.vaultId, connectionId: target.connectionId, in: db
                ) else { return }
                try db.execute(
                    sql: "UPDATE vaults SET syncMeetingEventsVersion = ? WHERE id = ? AND syncMeetingEventsVersion != ?",
                    arguments: [meetingEventsVersion, target.vaultId, meetingEventsVersion]
                )
            }
        } catch let error as SyncHTTPError where error.status == 426 {
            try await setRecoveryState("updateRequired", target: target)
            throw error
        }
        if try await dbQueue
            .read({ try String.fetchOne($0, sql: "SELECT syncRecoveryState FROM vaults WHERE id = ?", arguments: [target.vaultId]) }) ==
            "updateRequired" {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE vaults SET syncRecoveryState = NULL WHERE id = ? AND accountConnectionId = ?",
                    arguments: [target.vaultId, target.connectionId]
                )
            }
        }
        if target.cursor == nil {
            try await recoverSnapshot(target)
            return true
        }

        var cursor = target.cursor
        var committedCursor = target.cursor
        var deferred = false
        var highWaterCursor: String?
        repeat {
            let page = try await loadChangePage(
                target: target,
                cursor: cursor,
                highWaterCursor: highWaterCursor
            )
            highWaterCursor = page.highWaterCursor
            if page.items.contains(where: { $0.entity == .vault && $0.action == "reset" }) {
                var snapshotItems = page.items
                var snapshotPage = page
                while snapshotPage.hasMore {
                    snapshotPage = try await loadChangePage(
                        target: target,
                        cursor: snapshotPage.cursor,
                        highWaterCursor: page.highWaterCursor
                    )
                    snapshotItems.append(contentsOf: snapshotPage.items)
                }
                let snapshot = Self.initialSnapshotChanges(snapshotItems)
                return try await applySnapshot(snapshot, cursor: snapshotPage.cursor, target: target)
            }
            switch try await applyIncrementalPage(page.items, target: target) {
            case .retry: return false
            case .deferred: deferred = true
            case .applied, .alreadyApplied: break
            }
            if !deferred {
                guard try await RemoteChangeApplier.advanceIncrementalCursor(
                    page.cursor,
                    from: committedCursor,
                    context: target.context,
                    dbQueue: dbQueue
                ) else { return false }
                committedCursor = page.cursor
            }
            // The scan may pass a protected item, but its durable cursor never does.
            cursor = page.cursor
            if !page.hasMore { break }
        } while true
        return !deferred
    }

    private func recoverSnapshot(_ target: SyncTarget) async throws {
        try await setRecoveryState("pending", target: target, resetCursor: true)
        let generation = try await RemoteChangeApplier.recoveryGeneration(
            vaultId: target.vaultId, expectedConnectionId: target.connectionId, dbQueue: dbQueue
        )
        let needsRevisions = try await dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sync_entity_state WHERE vaultId = ? AND entity = 'vault' AND confirmedRevision IS NULL)",
                arguments: [target.vaultId]
            ) ?? false
        }
        guard generation != nil || needsRevisions else { return }
        try await setRecoveryState("recovering", target: target)
        do {
            let completed = try await fetchAndApplySnapshot(target, generation: generation)
            if !completed { try await setRecoveryState("pending", target: target) }
        } catch {
            let state = (error as? SyncHTTPError)?.status == 426 ? "updateRequired" : "pending"
            try? await setRecoveryState(state, target: target)
            throw error
        }
        await vaultsDidChange()
    }

    private func setRecoveryState(_ state: String, target: SyncTarget, resetCursor: Bool = false) async throws {
        try await dbQueue.write { db in
            guard try SyncTransactionQueue.matchesExpectedConnection(
                vaultId: target.vaultId, connectionId: target.connectionId, in: db
            ) else { return }
            try db.execute(
                sql: "UPDATE vaults SET syncRecoveryState = ?, syncPullCursor = CASE WHEN ? THEN NULL ELSE syncPullCursor END WHERE id = ?",
                arguments: [state, resetCursor, target.vaultId]
            )
        }
    }

    private func fetchAndApplySnapshot(_ target: SyncTarget, generation: Int64?) async throws -> Bool {
        let staged = try SyncSnapshotStore()
        var position: String?
        var startCursor: String?
        repeat {
            try Task.checkCancellation()
            var components = URLComponents()
            components.path = "/api/v1/vaults/\(target.vaultId.lowercase)/snapshot"
            components.queryItems = []
            if let position { components.queryItems?.append(URLQueryItem(name: "cursor", value: position)) }
            if let startCursor { components.queryItems?.append(URLQueryItem(name: "startCursor", value: startCursor)) }
            guard let path = components.string else { throw URLError(.badURL) }
            let page = try await SyncJSON.decoder.decode(
                SyncSnapshotPage.self,
                from: sendData(request(origin: target.origin, path: path, method: "GET"), connectionId: target.connectionId)
            )
            if let startCursor, startCursor != page.startCursor { throw SyncTransactionQueueError.invalidReceipt }
            try await staged.merge(page.items.map {
                SyncChangePage.Change(sequence: 0, entity: $0.entity, entityId: $0.id, action: "upsert", revision: $0.revision, record: $0.record)
            })
            startCursor = page.startCursor
            guard page.nextCursor == nil || page.nextCursor != position else { throw SyncTransactionQueueError.invalidReceipt }
            position = page.nextCursor
        } while position != nil

        var cursor = startCursor
        var highWater: String?
        var deletedVault: SyncChangePage.Change?
        repeat {
            try Task.checkCancellation()
            let page = try await loadChangePage(target: target, cursor: cursor, highWaterCursor: highWater)
            highWater = page.highWaterCursor
            for change in page.items where change.entity == .vault && change.action == "reset" {
                deletedVault = change.record == nil ? change : nil
            }
            try await staged.merge(page.items)
            guard !page.hasMore || page.cursor != cursor else { throw SyncTransactionQueueError.invalidReceipt }
            cursor = page.cursor
            if !page.hasMore { break }
        } while true

        if let deletedVault, let generation {
            return try await RemoteChangeApplier.apply(
                [deletedVault], screenshots: [:], transcripts: [:], cursor: nil,
                vaultId: target.vaultId, expectedConnectionId: target.connectionId,
                dbQueue: dbQueue, expectedMutationGeneration: generation
            )
        }
        // Only the existing explicit Server-adoption path may initialize unknown base revisions.
        // Cursor expiry must never rebase ordinary offline edits onto a newer Server revision.
        try await SyncTransactionQueue.reconcileRevisions(
            staged.revisionChanges(), vaultId: target.vaultId, connectionId: target.connectionId, dbQueue: dbQueue
        )
        guard let generation else { return false }
        guard try await RemoteChangeApplier.reconcileRecoveryProjects(
            staged.projects(), vaultId: target.vaultId, expectedConnectionId: target.connectionId,
            dbQueue: dbQueue, generation: generation
        ) else { return false }
        let snapshotTarget = SyncTarget(
            vaultId: target.vaultId,
            connectionId: target.connectionId,
            origin: target.origin,
            cursor: nil,
            mutationGeneration: generation
        )
        var last: SyncChangePage.Change?
        while true {
            try Task.checkCancellation()
            let page = try await staged.page(after: last)
            if page.isEmpty { break }
            guard try await apply(
                page.filter { $0.entity != .project }, cursor: nil, target: snapshotTarget, expectedMutationGeneration: generation
            ) else { return false }
            last = page.last
        }
        return try await RemoteChangeApplier.finishReset(
            staged.resetSnapshot(), cursor: cursor, vaultId: target.vaultId, expectedConnectionId: target.connectionId,
            dbQueue: dbQueue, expectedMutationGeneration: generation
        )
    }

    private func applySnapshot(
        _ changes: [SyncChangePage.Change],
        cursor: String?,
        target: SyncTarget,
        reconcilesMissingRecords: Bool = false
    ) async throws -> Bool {
        let reset = reconcilesMissingRecords ? SyncResetSnapshot(canonicalChanges: changes) : SyncResetSnapshot(changes)
        guard let reset else {
            guard let applicable = try await reconcilingDependencies(in: changes, target: target) else { return false }
            return try await apply(applicable, cursor: cursor, target: target)
        }
        guard try await apply(changes, cursor: nil, target: target) else { return false }
        return try await RemoteChangeApplier.finishReset(
            reset,
            cursor: cursor,
            vaultId: target.vaultId,
            expectedConnectionId: target.connectionId,
            dbQueue: dbQueue
        )
    }

    private func reconcilingDependencies(
        in changes: [SyncChangePage.Change],
        target: SyncTarget,
        incrementalContext: RemoteChangePolicy.Context? = nil
    ) async throws -> [SyncChangePage.Change]? {
        let missingMeetingIDs = try await Self.missingParentMeetingIDs(
            in: changes,
            vaultId: target.vaultId,
            dbQueue: dbQueue
        )
        var parentMeetings: [SyncChangePage.Change] = []
        for meetingId in missingMeetingIDs {
            let data = try await sendData(
                request(
                    origin: target.origin,
                    path: "api/v1/vaults/\(target.vaultId.lowercase)/meetings/\(meetingId.lowercase)",
                    method: "GET"
                ),
                connectionId: target.connectionId
            )
            let header = try SyncJSON.decoder.decode(SyncMeetingSnapshotHeader.self, from: data)
            let record = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: data)
            parentMeetings.append(.init(
                sequence: 0,
                entity: .meeting,
                entityId: header.meetingId,
                action: "upsert",
                revision: header.revision,
                record: record
            ))
        }
        var parentFiles: [SyncChangePage.Change] = []
        for fileId in try await Self.missingParentFileIDs(in: changes, vaultId: target.vaultId, dbQueue: dbQueue) {
            if let canonical = changes.first(where: { $0.entity == .file && $0.entityId == fileId && $0.action == "upsert" }) {
                parentFiles.append(canonical)
                continue
            }
            let data = try await sendData(
                request(origin: target.origin, path: "api/v1/files/\(fileId.lowercase)/metadata", method: "GET"),
                connectionId: target.connectionId
            )
            struct Header: Decodable { let id: UUID
                let vaultId: UUID
                let revision: Int
            }
            let header = try SyncJSON.decoder.decode(Header.self, from: data)
            guard header.id == fileId, header.vaultId == target.vaultId else { throw SyncTransactionQueueError.invalidReceipt }
            var payload = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: data)
            // Dependency reconciliation observes metadata; the body provider owns text completion.
            payload.contentOmitted = true
            payload.contentPresent = true
            payload.metadata?.ocrText = nil
            payload.metadata?.caption = nil
            parentFiles.append(.init(
                sequence: 0,
                entity: .file,
                entityId: fileId,
                action: "upsert",
                revision: header.revision,
                record: payload
            ))
        }
        guard try await reconcilingProjects(in: parentMeetings + changes, target: target, incrementalContext: incrementalContext) != nil
        else { return nil }
        if incrementalContext != nil {
            let result = try await applyIncrementalPage(parentFiles + parentMeetings, target: target)
            guard result == .applied else { return nil }
        } else {
            guard try await apply(parentFiles + parentMeetings, cursor: nil, target: target) else { return nil }
        }
        return changes.filter { $0.entity != .project }
    }

    private func reconcilingProjects(
        in changes: [SyncChangePage.Change],
        target: SyncTarget,
        incrementalContext: RemoteChangePolicy.Context? = nil
    ) async throws -> [SyncChangePage.Change]? {
        guard try await Self.needsProjectReconciliation(
            changes,
            vaultId: target.vaultId,
            dbQueue: dbQueue
        ),
            !changes.contains(where: {
                $0.entity == .vault && $0.action == "reset"
            }) else {
            return changes
        }
        let data = try await sendData(
            request(
                origin: target.origin,
                path: "api/v1/vaults/\(target.vaultId.lowercase)/projects",
                method: "GET"
            ),
            connectionId: target.connectionId
        )
        let projects = try SyncJSON.decoder.decode(SyncProjectSnapshotPage.self, from: data).items
        guard try await RemoteChangeApplier.reconcileProjectSnapshot(
            projects,
            vaultId: target.vaultId,
            expectedConnectionId: target.connectionId,
            dbQueue: dbQueue,
            incrementalContext: incrementalContext
        ) else {
            return nil
        }
        return changes.filter { $0.entity != .project }
    }

    static func needsProjectReconciliation(
        _ changes: [SyncChangePage.Change],
        vaultId: UUID,
        dbQueue: DatabaseQueue
    ) async throws -> Bool {
        if changes.contains(where: { $0.entity == .project }) { return true }
        let referencedProjectIDs = Set(changes.compactMap { change in
            change.entity == .meeting && change.action == "upsert" ? change.record?.projectId : nil
        })
        guard !referencedProjectIDs.isEmpty else { return false }
        return try await dbQueue.read { db in
            try referencedProjectIDs.contains { projectID in
                try ProjectRecord
                    .filter(Column("id") == projectID && Column("vaultId") == vaultId)
                    .fetchCount(db) == 0
            }
        }
    }

    static func missingParentMeetingIDs(
        in changes: [SyncChangePage.Change],
        vaultId: UUID,
        dbQueue: DatabaseQueue
    ) async throws -> [UUID] {
        let referencedMeetingIDs = Set(changes.compactMap { change -> UUID? in
            guard change.action == "upsert" else { return nil }
            switch change.entity {
            case .summary, .transcript:
                return change.entityId
            case .meetingFile, .recording:
                return change.record?.meetingId
            case .vault, .project, .meeting, .file, .meetingEvent:
                return nil
            }
        })
        guard !referencedMeetingIDs.isEmpty else { return [] }
        return try await dbQueue.read { db in
            try referencedMeetingIDs.filter { meetingID in
                try MeetingRecord
                    .filter(Column("id") == meetingID && Column("vaultId") == vaultId)
                    .fetchCount(db) == 0
            }.sorted { $0.uuidString < $1.uuidString }
        }
    }

    static func missingParentFileIDs(in changes: [SyncChangePage.Change], vaultId: UUID, dbQueue: DatabaseQueue) async throws -> [UUID] {
        let referenced = Set(changes.compactMap { change in
            change.entity == .meetingFile && change.action == "upsert" ? change.record?.fileId : nil
        })
        return try await dbQueue.read { db in
            try referenced.filter { id in
                try FileRecord.filter(Column("id") == id && Column("vaultId") == vaultId).fetchCount(db) == 0
            }.sorted { $0.uuidString < $1.uuidString }
        }
    }

    private func loadChangePage(
        target: SyncTarget,
        cursor: String?,
        highWaterCursor: String?
    ) async throws -> SyncChangePage {
        var components = URLComponents()
        components.path = "/api/v1/vaults/\(target.vaultId.lowercase)/changes"
        components.queryItems = [
            cursor.map { URLQueryItem(name: "cursor", value: $0) },
            highWaterCursor.map { URLQueryItem(name: "highWaterCursor", value: $0) },
        ].compactMap(\.self)
        guard let path = components.string else { throw URLError(.badURL) }
        let data = try await sendData(
            request(origin: target.origin, path: path, method: "GET"),
            connectionId: target.connectionId
        )
        return try SyncJSON.decoder.decode(SyncChangePage.self, from: data)
    }

    private func applyIncrementalPage(_ changes: [SyncChangePage.Change], target: SyncTarget) async throws -> RemoteChangePolicy.Result {
        var deferred = false
        for change in changes {
            try Task.checkCancellation()
            let decision = try await dbQueue.read { try RemoteChangePolicy.decision(change, context: target.context, in: $0) }
            switch decision {
            case .retry:
                if try await dbQueue.read({ try target.context.isCurrent(in: $0) }) {
                    // A fresh canonical revision lower than our copy requires the existing fenced snapshot recovery.
                    try await recoverSnapshot(target)
                }
                return .retry
            case .deferred:
                deferred = true
                continue
            case .alreadyApplied, .applied: break
            }
            guard try await reconcilingDependencies(in: [change], target: target, incrementalContext: target.context) != nil else {
                guard try await dbQueue.read({ try target.context.isCurrent(in: $0) }) else { return .retry }
                deferred = true
                continue
            }
            if change.entity == .project { continue } // Project hierarchy was reconciled as a unit above.
            let result = try await RemoteChangeApplier.applyIncremental(change, context: target.context, dbQueue: dbQueue)
            switch result {
            case .retry: return .retry
            case .deferred: deferred = true
            case .applied, .alreadyApplied: break
            }
        }
        return deferred ? .deferred : .applied
    }

    private func apply(
        _ changes: [SyncChangePage.Change],
        cursor: String?,
        target: SyncTarget,
        expectedMutationGeneration: Int64? = nil
    ) async throws -> Bool {
        guard !changes.isEmpty else {
            guard let cursor else { return true }
            return try await RemoteChangeApplier.advancePullCursor(
                cursor,
                vaultId: target.vaultId,
                expectedConnectionId: target.connectionId,
                dbQueue: dbQueue,
                expectedMutationGeneration: expectedMutationGeneration
            )
        }
        for (index, change) in changes.enumerated() {
            guard try await !SyncTransactionQueue.hasPending(
                vaultId: target.vaultId,
                dbQueue: dbQueue
            ) else { return false }
            let appliedCursor = index == changes.indices.last ? cursor : nil
            if target.cursor != nil, change.action != "reset", try await SyncTransactionQueue.isConfirmed(
                vaultId: target.vaultId,
                entity: change.entity,
                entityId: change.entityId,
                revision: change.revision,
                dbQueue: dbQueue
            ) {
                if let appliedCursor,
                   try await !RemoteChangeApplier.advancePullCursor(
                       appliedCursor,
                       vaultId: target.vaultId,
                       expectedConnectionId: target.connectionId,
                       dbQueue: dbQueue,
                       expectedMutationGeneration: expectedMutationGeneration
                   ) { return false }
                continue
            }
            guard try await RemoteChangeApplier.apply(
                [change],
                screenshots: [:],
                transcripts: [:],
                cursor: appliedCursor,
                vaultId: target.vaultId,
                expectedConnectionId: target.connectionId,
                dbQueue: dbQueue,
                expectedMutationGeneration: expectedMutationGeneration
            ) else { return false }
        }
        return true
    }

    static func initialSnapshotChanges(_ changes: [SyncChangePage.Change]) -> [SyncChangePage.Change] {
        let reset = changes.filter { $0.entity == .vault && $0.action == "reset" }.max { $0.sequence < $1.sequence }
        var current: [String: SyncChangePage.Change] = [:]
        for change in changes where change.action != "reset" && change.sequence > (reset?.sequence ?? 0) {
            current["\(change.entity.rawValue):\(change.entityId.uuidString)"] = change
        }
        let upserts = current.values.filter { $0.action == "upsert" && $0.record != nil }
        var projects = upserts.filter { $0.entity == .project }
        var orderedProjects: [SyncChangePage.Change] = []
        while !projects.isEmpty {
            let projectIDs = Set(projects.map(\.entityId))
            let ready = projects.filter { change in
                guard let parent = change.record?.parentProjectId else { return true }
                return !projectIDs.contains(parent)
            }.sorted { $0.entityId.uuidString < $1.entityId.uuidString }
            guard !ready.isEmpty else {
                orderedProjects.append(contentsOf: projects.sorted { $0.entityId.uuidString < $1.entityId.uuidString })
                break
            }
            let readyIDs = Set(ready.map(\.entityId))
            orderedProjects.append(contentsOf: ready)
            projects.removeAll { readyIDs.contains($0.entityId) }
        }
        func sorted(_ entity: SyncEntity) -> [SyncChangePage.Change] {
            upserts.filter { $0.entity == entity }.sorted { $0.entityId.uuidString < $1.entityId.uuidString }
        }
        let deletes = current.values.filter { $0.action == "delete" }.sorted { $0.sequence < $1.sequence }
        return (reset.map { [$0] } ?? []) + sorted(.vault) + orderedProjects + sorted(.meeting) + sorted(.summary)
            + sorted(.transcript) + sorted(.file) + sorted(.meetingFile) + deletes
    }

    private func pullTargets() async throws -> [SyncTarget] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT vaults.id, vaults.syncConfirmedConnectionId, vaults.syncPullCursor, vaults.syncMutationGeneration,
                    dahlia_account_connections.origin
                FROM vaults
                JOIN dahlia_account_connections
                  ON dahlia_account_connections.id = vaults.syncConfirmedConnectionId
                WHERE vaults.accountConnectionId = vaults.syncConfirmedConnectionId
                  AND (
                    (vaults.syncPullCursor IS NOT NULL AND vaults.syncRecoveryState IS NULL)
                    OR NOT EXISTS (SELECT 1 FROM sync_transactions WHERE vaultId = vaults.id)
                    OR EXISTS (
                      SELECT 1 FROM sync_entity_state s
                      WHERE s.vaultId = vaults.id AND s.entity = 'vault' AND s.entityId = vaults.id
                        AND s.confirmedRevision IS NULL
                    )
                  )
                """
            ).compactMap { row in
                guard let origin = URL(string: row["origin"] as String) else { return nil }
                return SyncTarget(
                    vaultId: row["id"],
                    connectionId: row["syncConfirmedConnectionId"],
                    origin: origin,
                    cursor: row["syncPullCursor"],
                    mutationGeneration: row["syncMutationGeneration"]
                )
            }
        }
    }

    private func restartEventStreams() async {
        let previousTasks = Array(eventTasks.values)
        previousTasks.forEach { $0.cancel() }
        for task in previousTasks {
            await task.value
        }
        eventTasks.removeAll()
        let connections = await (try? dbQueue.read { db in
            try DahliaAccountConnectionRecord.fetchAll(db)
        }) ?? []
        for connection in connections where eventTasks[connection.id] == nil {
            guard let origin = URL(string: connection.origin) else { continue }
            eventTasks[connection.id] = Task { [weak self] in
                await self?.consumeEvents(connectionId: connection.id, origin: origin)
            }
        }
    }

    private func consumeEvents(connectionId: UUID, origin: URL) async {
        while !Task.isCancelled {
            do {
                var eventRequest = try request(origin: origin, path: "api/v1/events", method: "GET")
                let token = try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(connectionID: connectionId)
                eventRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (bytes, response) = try await session.bytes(for: eventRequest)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                _ = await MainActor.run { ServerAccountSettingsModel.shared.refresh(connectionID: connectionId) }
                var event = ""
                for try await line in bytes.lines {
                    guard !Task.isCancelled else { return }
                    if line.hasPrefix("event:") {
                        event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        if event == "account_settings" {
                            _ = await MainActor.run { ServerAccountSettingsModel.shared.refresh(connectionID: connectionId) }
                        } else {
                            try await pullRemoteChanges()
                        }
                        event = ""
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func connection(id: UUID) async throws -> URL? {
        try await dbQueue.read { db in
            try DahliaAccountConnectionRecord.fetchOne(db, key: id).flatMap { URL(string: $0.origin) }
        }
    }

    private func request(
        origin: URL,
        path: String,
        method: String,
        body: Data? = nil,
        contentType: String? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let body { request.setValue(String(body.count), forHTTPHeaderField: "Content-Length") }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func send(_ request: URLRequest, connectionId: UUID) async throws {
        _ = try await perform(request, connectionId: connectionId)
    }

    private func sendData(_ request: URLRequest, connectionId: UUID) async throws -> Data {
        try await perform(request, connectionId: connectionId)
    }

    private func perform(_ unsignedRequest: URLRequest, connectionId: UUID) async throws -> Data {
        do {
            return try await apiClient.data(for: unsignedRequest, connectionId: connectionId)
        } catch let error as SyncHTTPError {
            let path = unsignedRequest.url?.path ?? ""
            if error.status == 404, error.code != "vault_not_found",
               path.hasSuffix("/snapshot") || path.hasSuffix("/transactions/resolve") || path.hasSuffix("/capabilities") {
                throw SyncHTTPError(status: 426, body: Data("{\"error\":\"sync_upgrade_required\"}".utf8))
            }
            throw error
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data?) throws -> T {
        guard let data else { throw SyncTransactionQueueError.invalidReceipt }
        return try SyncJSON.decoder.decode(type, from: data)
    }
}

struct ServerCapabilities: Decodable {
    struct Feature: Decodable {
        let version: Int
    }

    struct MeetingSummaryGeneration: Decodable {
        let version: Int
        let sources: [String]

        private enum CodingKeys: String, CodingKey {
            case version, sources
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            // Future summary payloads must not disable unrelated capabilities.
            sources = version == 1 ? try container.decode([String].self, forKey: .sources) : []
        }
    }

    let sync: Feature?
    let recordingArchive: Feature?
    let meetingEvents: Feature?
    let search: Feature?
    let imageAnalysis: Feature?
    let meetingSummaryGeneration: MeetingSummaryGeneration?
}

private extension UUID {
    var lowercase: String { uuidString.lowercased() }
}
