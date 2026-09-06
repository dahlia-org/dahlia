import CryptoKit
import DahliaRuntimeSupport
import Foundation
import GRDB

private struct SyncHTTPError: Error {
    let status: Int
    let body: Data

    var code: String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: String] else { return nil }
        return object["error"]
    }

    var blockedReason: SyncBlockedReason? {
        switch status {
        case 401, 403: .authorization
        case 409: .conflict
        case 400 ..< 500 where ![408, 425, 429].contains(status): .validation
        default: nil
        }
    }
}

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

private struct SyncTransactionResolution: Decodable {
    let id: UUID
    let status: String
}

private struct SyncTransactionBody: Encodable {
    let schemaVersion = 1
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

private struct ScreenshotOperationData: Decodable {
    let meetingId: UUID
    let capturedAt: Date?
    let contentHash: String?
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

    init(ids: [SyncEntity: Set<UUID>]) {
        projects = ids[.project, default: []]
        meetings = ids[.meeting, default: []]
        summaries = ids[.summary, default: []]
        transcripts = ids[.transcript, default: []]
        screenshots = ids[.screenshot, default: []]
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
        screenshots = ids(.screenshot)
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
}

actor SyncWorker {
    private static let transcriptChunkSize = 500
    private static let remoteTranscriptWriteBatchSize = 500
    private static let transcriptChunkMaximumBytes = 6 * 1024 * 1024
    private static let transcriptPatchItemLimit = 50000
    private static let transcriptPatchMaximumChunks = 100

    private let dbQueue: DatabaseQueue
    private let session: URLSession
    private let vaultsDidChange: @MainActor @Sendable () async -> Void
    private var drainTask: Task<Void, Never>?
    private var eventTasks: [UUID: Task<Void, Never>] = [:]
    private var isPulling = false

    init(
        dbQueue: DatabaseQueue,
        session: URLSession = .shared,
        vaultsDidChange: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.dbQueue = dbQueue
        self.session = session
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
        while !Task.isCancelled {
            do {
                try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: dbQueue)
                guard let transaction = try await SyncTransactionQueue.claim(dbQueue: dbQueue) else {
                    try await pullRemoteChanges()
                    try await Task.sleep(for: .seconds(5))
                    continue
                }
                do {
                    let response = try await push(transaction)
                    try await SyncTransactionQueue.complete(transaction, response: response, dbQueue: dbQueue)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as SyncHTTPError {
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

    private func push(_ transaction: SyncQueuedTransaction) async throws -> SyncTransactionResponse {
        guard let target = try await connection(id: transaction.connectionId) else {
            throw SyncHTTPError(status: 403, body: Data("{\"error\":\"connection_missing\"}".utf8))
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
            if stageAttachments, operation.entity == .screenshot,
               operation.action != .delete,
               let attachment = try await SyncTransactionQueue.screenshotAttachment(
                   operationId: operation.id,
                   dbQueue: dbQueue
               ) {
                let payload = try decode(ScreenshotOperationData.self, from: operation.payloadJSON)
                var upload = try request(
                    origin: target,
                    path: "api/v1/vaults/\(transaction.vaultId.lowercase)/meetings/\(payload.meetingId.lowercase)/screenshots/\(operation.entityId.lowercase)/content",
                    method: "PUT",
                    body: attachment.bytes,
                    contentType: attachment.mimeType
                )
                if let capturedAt = payload.capturedAt {
                    upload.setValue(capturedAt.ISO8601Format(), forHTTPHeaderField: "X-Dahlia-Captured-At")
                }
                upload.setValue(attachment.sha256, forHTTPHeaderField: "X-Dahlia-Content-SHA256")
                try await send(upload, connectionId: transaction.connectionId)
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

    private func pullRemoteChanges() async throws {
        guard !isPulling else { return }
        isPulling = true
        defer { isPulling = false }
        for target in try await pullTargets() {
            do {
                try await pullRemoteChanges(for: target)
            } catch is CancellationError {
                throw CancellationError()
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

    private func pullRemoteChanges(for target: SyncTarget) async throws {
        if target.cursor == nil {
            try await recoverSnapshot(target)
            return
        }

        var cursor = target.cursor
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
                _ = try await applySnapshot(snapshot, cursor: snapshotPage.cursor, target: target)
                return
            }
            guard let applicable = try await reconcilingDependencies(in: page.items, target: target) else {
                return
            }
            guard try await apply(applicable, cursor: page.cursor, target: target) else {
                return
            }
            cursor = page.cursor
            if !page.hasMore { break }
        } while true
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
        target: SyncTarget
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
        guard try await reconcilingProjects(in: parentMeetings + changes, target: target) != nil,
              try await apply(parentMeetings, cursor: nil, target: target) else {
            return nil
        }
        return changes.filter { $0.entity != .project }
    }

    private func reconcilingProjects(
        in changes: [SyncChangePage.Change],
        target: SyncTarget
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
            dbQueue: dbQueue
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
            case .screenshot:
                return change.record?.meetingId
            case .vault, .project, .meeting:
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
            if change.entity == .transcript, change.action == "upsert" {
                guard try await applyTranscriptChange(
                    change,
                    cursor: appliedCursor,
                    target: target,
                    expectedMutationGeneration: expectedMutationGeneration
                ) else {
                    return false
                }
                continue
            }
            let supplemental = try await loadSupplemental([change], target: target)
            guard try await RemoteChangeApplier.apply(
                [change],
                screenshots: supplemental.screenshots,
                transcripts: supplemental.transcripts,
                cursor: appliedCursor,
                vaultId: target.vaultId,
                expectedConnectionId: target.connectionId,
                dbQueue: dbQueue,
                expectedMutationGeneration: expectedMutationGeneration
            ) else { return false }
        }
        return true
    }

    private func applyTranscriptChange(
        _ change: SyncChangePage.Change,
        cursor appliedCursor: String?,
        target: SyncTarget,
        expectedMutationGeneration: Int64? = nil
    ) async throws -> Bool {
        guard let revision = change.revision,
              try await RemoteChangeApplier.beginTranscript(
                  meetingId: change.entityId,
                  vaultId: target.vaultId,
                  expectedConnectionId: target.connectionId,
                  dbQueue: dbQueue,
                  expectedMutationGeneration: expectedMutationGeneration
              )
        else { return false }

        var cursor: String?
        repeat {
            var components = URLComponents()
            components.path = "/api/v1/vaults/\(target.vaultId.lowercase)/meetings/\(change.entityId.lowercase)/transcript"
            if let cursor { components.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
            guard let path = components.string else { throw URLError(.badURL) }
            let page = try await SyncJSON.decoder.decode(
                SyncTranscriptPage.self,
                from: sendData(
                    request(origin: target.origin, path: path, method: "GET"),
                    connectionId: target.connectionId
                )
            )
            for offset in stride(from: 0, to: page.items.count, by: Self.remoteTranscriptWriteBatchSize) {
                let end = min(offset + Self.remoteTranscriptWriteBatchSize, page.items.count)
                guard try await RemoteChangeApplier.applyTranscriptPage(
                    Array(page.items[offset ..< end]),
                    meetingId: change.entityId,
                    vaultId: target.vaultId,
                    expectedConnectionId: target.connectionId,
                    dbQueue: dbQueue,
                    expectedMutationGeneration: expectedMutationGeneration
                ) else { return false }
            }
            cursor = page.nextCursor
        } while cursor != nil

        return try await RemoteChangeApplier.finishTranscript(
            meetingId: change.entityId,
            revision: revision,
            cursor: appliedCursor,
            vaultId: target.vaultId,
            expectedConnectionId: target.connectionId,
            dbQueue: dbQueue,
            expectedMutationGeneration: expectedMutationGeneration
        )
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
            + sorted(.transcript) + sorted(.screenshot) + deletes
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
                    NOT EXISTS (SELECT 1 FROM sync_transactions WHERE vaultId = vaults.id)
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

    private func loadSupplemental(
        _ changes: [SyncChangePage.Change],
        target: SyncTarget
    ) async throws -> (screenshots: [UUID: Data], transcripts: [UUID: [SyncTranscriptPage.Segment]]) {
        var screenshots: [UUID: Data] = [:]
        let transcripts: [UUID: [SyncTranscriptPage.Segment]] = [:]
        for change in changes where change.action == "upsert" {
            if change.entity == .screenshot, let meetingId = change.record?.meetingId {
                let data = try await sendData(
                    request(
                        origin: target.origin,
                        path: "api/v1/vaults/\(target.vaultId.lowercase)/meetings/\(meetingId.lowercase)/screenshots/\(change.entityId.lowercase)/content",
                        method: "GET"
                    ),
                    connectionId: target.connectionId
                )
                guard let expectedHash = change.record?.contentHash,
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedHash else {
                    throw SyncTransactionQueueError.invalidReceipt
                }
                screenshots[change.entityId] = data
            }
        }
        return (screenshots, transcripts)
    }

    private func restartEventStreams() async {
        let previousTasks = Array(eventTasks.values)
        previousTasks.forEach { $0.cancel() }
        for task in previousTasks {
            await task.value
        }
        eventTasks.removeAll()
        let connections = await (try? dbQueue.read { db in
            try DahliaAccountConnectionRecord.fetchAll(
                db,
                sql: """
                SELECT DISTINCT c.*
                FROM dahlia_account_connections c
                JOIN vaults v ON v.syncConfirmedConnectionId = c.id
                WHERE v.accountConnectionId = c.id
                """
            )
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
                for try await line in bytes.lines where line.hasPrefix("data:") {
                    guard !Task.isCancelled else { return }
                    try await pullRemoteChanges()
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
        var forceRefresh = false
        for attempt in 0 ... 1 {
            var request = unsignedRequest
            let token = try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(
                connectionID: connectionId,
                forceRefresh: forceRefresh
            )
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if (200 ..< 300).contains(http.statusCode) { return data }
            if http.statusCode == 401, attempt == 0 {
                forceRefresh = true
                continue
            }
            let error = SyncHTTPError(status: http.statusCode, body: data)
            let path = unsignedRequest.url?.path ?? ""
            if http.statusCode == 404, error.code != "vault_not_found",
               path.hasSuffix("/snapshot") || path.hasSuffix("/transactions/resolve") {
                throw SyncHTTPError(status: 426, body: Data("{\"error\":\"sync_upgrade_required\"}".utf8))
            }
            throw error
        }
        throw SyncHTTPError(status: 401, body: Data())
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data?) throws -> T {
        guard let data else { throw SyncTransactionQueueError.invalidReceipt }
        return try SyncJSON.decoder.decode(type, from: data)
    }
}

private extension UUID {
    var lowercase: String { uuidString.lowercased() }
}
