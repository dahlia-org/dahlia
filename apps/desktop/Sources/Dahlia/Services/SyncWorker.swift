import CryptoKit
import DahliaRuntimeSupport
import Foundation
import GRDB

private struct SyncHTTPError: Error {
    let status: Int
    let body: Data

    var blockedReason: SyncBlockedReason? {
        switch status {
        case 401, 403: .authorization
        case 409: .conflict
        case 400 ..< 500 where ![408, 425, 429].contains(status): .validation
        default: nil
        }
    }
}

private struct SyncOperationBody: Encodable {
    let id: UUID
    let entity: SyncEntity
    let action: SyncAction
    let entityId: UUID
    let baseRevision: Int?
    let data: JSONValue?
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
    struct Change: Decodable {
        let sequence: Int
        let entity: SyncEntity
        let entityId: UUID
        let action: String
        let revision: Int?
        let record: SyncCanonicalPayload?
    }

    let items: [Change]
    let cursor: String
    let hasMore: Bool
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
}

actor SyncWorker {
    private static let transcriptChunkSize = 500
    private static let transcriptChunkMaximumBytes = 6 * 1024 * 1024

    private let dbQueue: DatabaseQueue
    private let session: URLSession
    private var drainTask: Task<Void, Never>?
    private var eventTasks: [UUID: Task<Void, Never>] = [:]
    private var isPulling = false

    init(
        dbQueue: DatabaseQueue,
        session: URLSession = .shared
    ) {
        self.dbQueue = dbQueue
        self.session = session
    }

    func start(restored: Bool) async {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            guard let self else { return }
            do {
                if restored { try await SyncInitialSnapshotBuilder.prepareRestore(dbQueue: dbQueue) }
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

    private func runDrain() async {
        while !Task.isCancelled {
            do {
                try await dbQueue.write { db in
                    try SyncInitialSnapshotBuilder.enqueuePending(in: db)
                }
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
        var operations = transaction.operations
        for index in operations.indices {
            let operation = operations[index]
            if operation.entity == .screenshot,
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
                let payload = try await stageTranscriptPatch(operation, transaction: transaction, origin: target)
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

        let body = try SyncJSON.encoder.encode(SyncTransactionBody(
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
        let data = try await sendData(
            request(origin: target, path: "api/v1/transactions", method: "POST", body: body, contentType: "application/json"),
            connectionId: transaction.connectionId
        )
        return try SyncJSON.decoder.decode(SyncTransactionResponse.self, from: data)
    }

    private func stageTranscriptPatch(
        _ operation: SyncQueuedOperation,
        transaction: SyncQueuedTransaction,
        origin: URL
    ) async throws -> Data {
        let snapshot = try await SyncTransactionQueue.transcriptPatch(operationId: operation.id, dbQueue: dbQueue)
        var chunks: [TranscriptPatchData.Chunk] = []
        for (index, chunk) in try Self.transcriptChunks(snapshot).enumerated() {
            let body = chunk.body
            let data = chunk.data
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            var upload = try request(
                origin: origin,
                path: "api/v1/vaults/\(transaction.vaultId.lowercase)/meetings/\(operation.entityId.lowercase)/transcripts/\(operation.id.lowercase)/chunks/\(index)",
                method: "PUT",
                body: data,
                contentType: "application/json"
            )
            upload.setValue(hash, forHTTPHeaderField: "X-Dahlia-Content-SHA256")
            try await send(upload, connectionId: transaction.connectionId)
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
            } catch {
                continue
            }
        }
    }

    private func pullRemoteChanges(for target: SyncTarget) async throws {
        if target.cursor == nil {
            var cursor: String?
            var changes: [String: SyncChangePage.Change] = [:]
            repeat {
                let page = try await loadChangePage(target: target, cursor: cursor)
                for change in page.items {
                    changes["\(change.entity.rawValue):\(change.entityId.uuidString)"] = change
                }
                cursor = page.cursor
                if !page.hasMore { break }
            } while true
            let snapshot = Self.initialSnapshotChanges(Array(changes.values))
            guard try await RemoteChangeApplier.reconcileProjectSnapshot(
                snapshot,
                vaultId: target.vaultId,
                dbQueue: dbQueue
            ) else {
                return
            }
            _ = try await apply(
                snapshot,
                cursor: cursor,
                target: target
            )
            return
        }

        var cursor = target.cursor
        repeat {
            let page = try await loadChangePage(target: target, cursor: cursor)
            let appliedAll = try await apply(coalesced(page.items), cursor: page.cursor, target: target)
            guard appliedAll else { break }
            cursor = page.cursor
            if !page.hasMore { break }
        } while true
    }

    private func loadChangePage(target: SyncTarget, cursor: String?) async throws -> SyncChangePage {
        var components = URLComponents()
        components.path = "/api/v1/vaults/\(target.vaultId.lowercase)/changes"
        if let cursor { components.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
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
        target: SyncTarget
    ) async throws -> Bool {
        guard !changes.isEmpty else {
            guard let cursor else { return true }
            return try await SyncTransactionQueue.advancePullCursor(
                cursor,
                vaultId: target.vaultId,
                dbQueue: dbQueue
            )
        }
        for (index, change) in changes.enumerated() {
            guard try await !SyncTransactionQueue.hasPending(
                vaultId: target.vaultId,
                dbQueue: dbQueue
            ) else { return false }
            let appliedCursor = index == changes.indices.last ? cursor : nil
            if try await SyncTransactionQueue.isConfirmed(
                vaultId: target.vaultId,
                entity: change.entity,
                entityId: change.entityId,
                revision: change.revision,
                dbQueue: dbQueue
            ) {
                if let appliedCursor,
                   try await !SyncTransactionQueue.advancePullCursor(
                       appliedCursor,
                       vaultId: target.vaultId,
                       dbQueue: dbQueue
                   ) { return false }
                continue
            }
            let supplemental = try await loadSupplemental([change], target: target)
            guard try await RemoteChangeApplier.apply(
                [change],
                screenshots: supplemental.screenshots,
                transcripts: supplemental.transcripts,
                cursor: appliedCursor,
                vaultId: target.vaultId,
                dbQueue: dbQueue
            ) else { return false }
        }
        return true
    }

    static func initialSnapshotChanges(_ changes: [SyncChangePage.Change]) -> [SyncChangePage.Change] {
        if let reset = changes.last(where: { $0.entity == .vault && $0.action == "reset" }) {
            return [reset]
        }
        var current: [String: SyncChangePage.Change] = [:]
        for change in changes {
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
        return sorted(.vault) + orderedProjects + sorted(.meeting) + sorted(.summary)
            + sorted(.transcript) + sorted(.screenshot) + deletes
    }

    private func coalesced(_ changes: [SyncChangePage.Change]) -> [SyncChangePage.Change] {
        var result: [SyncChangePage.Change] = []
        for change in changes {
            if let previous = result.last,
               previous.entity == change.entity,
               previous.entityId == change.entityId {
                result[result.count - 1] = change
            } else {
                result.append(change)
            }
        }
        return result
    }

    private func pullTargets() async throws -> [SyncTarget] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT vaults.id, vaults.syncConfirmedConnectionId, vaults.syncPullCursor,
                    dahlia_account_connections.origin
                FROM vaults
                JOIN dahlia_account_connections
                  ON dahlia_account_connections.id = vaults.syncConfirmedConnectionId
                WHERE vaults.syncEnabled = 1
                  AND vaults.accountConnectionId = vaults.syncConfirmedConnectionId
                  AND NOT EXISTS (SELECT 1 FROM sync_transactions WHERE vaultId = vaults.id)
                """
            ).compactMap { row in
                guard let origin = URL(string: row["origin"] as String) else { return nil }
                return SyncTarget(
                    vaultId: row["id"],
                    connectionId: row["syncConfirmedConnectionId"],
                    origin: origin,
                    cursor: row["syncPullCursor"]
                )
            }
        }
    }

    private func loadSupplemental(
        _ changes: [SyncChangePage.Change],
        target: SyncTarget
    ) async throws -> (screenshots: [UUID: Data], transcripts: [UUID: [SyncTranscriptPage.Segment]]) {
        var screenshots: [UUID: Data] = [:]
        var transcripts: [UUID: [SyncTranscriptPage.Segment]] = [:]
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
            } else if change.entity == .transcript {
                transcripts[change.entityId] = try await loadTranscript(meetingId: change.entityId, target: target)
            }
        }
        return (screenshots, transcripts)
    }

    private func loadTranscript(meetingId: UUID, target: SyncTarget) async throws -> [SyncTranscriptPage.Segment] {
        var result: [SyncTranscriptPage.Segment] = []
        var cursor: String?
        repeat {
            var components = URLComponents()
            components.path = "/api/v1/vaults/\(target.vaultId.lowercase)/meetings/\(meetingId.lowercase)/transcript"
            if let cursor { components.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
            guard let path = components.string else { throw URLError(.badURL) }
            let page = try await SyncJSON.decoder.decode(
                SyncTranscriptPage.self,
                from: sendData(
                    request(origin: target.origin, path: path, method: "GET"),
                    connectionId: target.connectionId
                )
            )
            result.append(contentsOf: page.items)
            cursor = page.nextCursor
        } while cursor != nil
        return result
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
                WHERE v.syncEnabled = 1
                  AND v.accountConnectionId = c.id
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
            throw SyncHTTPError(status: http.statusCode, body: data)
        }
        throw SyncHTTPError(status: 401, body: Data())
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data?) throws -> T {
        guard let data else { throw SyncTransactionQueueError.invalidReceipt }
        return try SyncJSON.decoder.decode(type, from: data)
    }
}

enum RemoteChangeApplier {
    static func reconcileProjectSnapshot(
        _ changes: [SyncChangePage.Change],
        vaultId: UUID,
        dbQueue: DatabaseQueue
    ) async throws -> Bool {
        guard !changes.contains(where: { $0.entity == .vault && $0.action == "reset" }) else { return true }
        let projects = changes.filter { $0.entity == .project }
        let meetings = changes.filter { $0.entity == .meeting && $0.action == "upsert" }
        return try await dbQueue.write { db in
            guard try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db) else { return false }

            try db.execute(sql: "UPDATE meetings SET projectId = NULL WHERE vaultId = ?", arguments: [vaultId])
            try db.execute(
                sql: "DELETE FROM projects WHERE vaultId = ? AND parentProjectId IS NOT NULL",
                arguments: [vaultId]
            )
            try db.execute(
                sql: "DELETE FROM projects WHERE vaultId = ? AND parentProjectId IS NULL",
                arguments: [vaultId]
            )
            try db.execute(
                sql: "DELETE FROM sync_entity_state WHERE vaultId = ? AND entity = 'project'",
                arguments: [vaultId]
            )

            for change in projects where change.action == "upsert" {
                guard let record = change.record else { continue }
                try SyncTransactionQueue.applyCanonical(
                    .project,
                    id: change.entityId,
                    vaultId: vaultId,
                    value: record,
                    in: db
                )
            }
            for change in projects {
                try db.execute(
                    sql: """
                    INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision)
                    VALUES (?, 'project', ?, ?)
                    ON CONFLICT(vaultId, entity, entityId) DO UPDATE SET
                        confirmedRevision = excluded.confirmedRevision
                    """,
                    arguments: [vaultId, change.entityId, change.revision]
                )
            }
            for change in meetings {
                try db.execute(
                    sql: "UPDATE meetings SET projectId = ? WHERE id = ? AND vaultId = ?",
                    arguments: [change.record?.projectId, change.entityId, vaultId]
                )
            }
            return true
        }
    }

    static func apply(
        _ changes: [SyncChangePage.Change],
        screenshots: [UUID: Data],
        transcripts: [UUID: [SyncTranscriptPage.Segment]],
        cursor: String?,
        vaultId: UUID,
        dbQueue: DatabaseQueue
    ) async throws -> Bool {
        try await dbQueue.write { db in
            guard try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db) else { return false }
            let deletingActiveMeeting = try changes.contains { change in
                guard change.entity == .meeting, change.action == "delete" else { return false }
                return try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS (
                        SELECT 1 FROM recording_sessions
                        WHERE meetingId = ? AND endedAt IS NULL
                    )
                    """,
                    arguments: [change.entityId]
                ) ?? false
            }
            guard !deletingActiveMeeting else { return false }
            for change in changes {
                if change.action == "delete" {
                    try delete(change.entity, id: change.entityId, vaultId: vaultId, in: db)
                } else if change.action == "reset" {
                    try SyncTransactionQueue.discard(vaultId: vaultId, in: db)
                    try db.execute(sql: "DELETE FROM sync_entity_state WHERE vaultId = ?", arguments: [vaultId])
                    try db.execute(
                        sql: """
                        UPDATE vaults SET syncEnabled = 0, syncConfirmedConnectionId = NULL,
                            syncPullCursor = NULL, syncLastCommittedCursor = NULL
                        WHERE id = ?
                        """,
                        arguments: [vaultId]
                    )
                    return true
                } else if let record = change.record {
                    try upsert(change, record: record, screenshots: screenshots, transcripts: transcripts, vaultId: vaultId, in: db)
                }
                try db.execute(
                    sql: """
                    INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(vaultId, entity, entityId) DO UPDATE SET
                        confirmedRevision = excluded.confirmedRevision
                    """,
                    arguments: [vaultId, change.entity, change.entityId, change.revision]
                )
            }
            if let cursor {
                try db.execute(sql: "UPDATE vaults SET syncPullCursor = ? WHERE id = ?", arguments: [cursor, vaultId])
            }
            return true
        }
    }

    private static func delete(_ entity: SyncEntity, id: UUID, vaultId: UUID, in db: Database) throws {
        switch entity {
        case .project:
            try db.execute(sql: "DELETE FROM projects WHERE id = ? AND vaultId = ?", arguments: [id, vaultId])
        case .meeting:
            try db.execute(sql: "DELETE FROM meetings WHERE id = ? AND vaultId = ?", arguments: [id, vaultId])
        case .summary:
            try db.execute(sql: "DELETE FROM summaries WHERE meetingId = ?", arguments: [id])
        case .transcript:
            try db.execute(sql: "DELETE FROM transcript_segments WHERE meetingId = ?", arguments: [id])
        case .screenshot:
            try db.execute(sql: "DELETE FROM screenshots WHERE id = ?", arguments: [id])
        case .vault:
            break
        }
    }

    private static func upsert(
        _ change: SyncChangePage.Change,
        record: SyncCanonicalPayload,
        screenshots: [UUID: Data],
        transcripts: [UUID: [SyncTranscriptPage.Segment]],
        vaultId: UUID,
        in db: Database
    ) throws {
        switch change.entity {
        case .vault, .project, .meeting, .summary:
            try SyncTransactionQueue.applyCanonical(
                change.entity,
                id: change.entityId,
                vaultId: vaultId,
                value: record,
                in: db
            )
        case .transcript:
            try applyTranscript(
                meetingId: change.entityId,
                segments: transcripts[change.entityId, default: []],
                in: db
            )
        case .screenshot:
            guard let meetingId = record.meetingId, let capturedAt = record.capturedAt,
                  let contentType = record.contentType, let image = screenshots[change.entityId] else { return }
            try db.execute(sql: """
            INSERT INTO screenshots(id, meetingId, capturedAt, imageData, mimeType, ocrText, caption)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET capturedAt = excluded.capturedAt,
                imageData = excluded.imageData, mimeType = excluded.mimeType,
                ocrText = excluded.ocrText, caption = excluded.caption
            """, arguments: [
                change.entityId, meetingId, capturedAt, image, contentType, record.ocrText, record.caption,
            ])
            try db.execute(
                sql: "DELETE FROM search_index_jobs WHERE indexKind = 'fts' AND targetKind = 'screenshotAnalysis' AND targetKey = ?",
                arguments: [change.entityId]
            )
            let generation = try Int.fetchOne(
                db,
                sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'"
            ) ?? 1
            try indexScreenshotDocument(id: change.entityId, generation: generation, in: db)
        }
    }

    static func applyTranscript(
        meetingId: UUID,
        segments: [SyncTranscriptPage.Segment],
        in db: Database
    ) throws {
        let canonicalIDs = segments.map(\.segmentId)
        if canonicalIDs.isEmpty {
            try db.execute(
                sql: "DELETE FROM transcript_segments WHERE meetingId = ? AND isConfirmed = 1",
                arguments: [meetingId]
            )
        } else {
            try db.execute(
                sql: """
                DELETE FROM transcript_segments
                WHERE meetingId = ? AND isConfirmed = 1
                  AND id NOT IN (\(canonicalIDs.map { _ in "?" }.joined(separator: ",")))
                """,
                arguments: StatementArguments([meetingId]) + StatementArguments(canonicalIDs)
            )
        }
        for segment in segments {
            try db.execute(sql: """
            INSERT INTO transcript_segments(
                id, meetingId, startTime, endTime, text, isConfirmed, audioSource, speakerLabel
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                meetingId = excluded.meetingId,
                startTime = excluded.startTime,
                endTime = excluded.endTime,
                text = excluded.text,
                isConfirmed = excluded.isConfirmed,
                audioSource = excluded.audioSource,
                speakerLabel = excluded.speakerLabel
            """, arguments: [
                segment.segmentId, meetingId, segment.startTime, segment.endTime,
                segment.text, segment.isConfirmed, segment.audioSource, segment.speakerLabel,
            ])
        }
    }
}

private extension UUID {
    var lowercase: String { uuidString.lowercased() }
}
