import CryptoKit
import Foundation
import GRDB

struct MeetingSyncTransactionResponse: Decodable, Sendable {
    struct Record: Decodable, Sendable {
        struct Canonical: Decodable, Sendable {
            let activeGeneration: String?
        }

        let entity: String
        let id: UUID
        let revision: Int?
        let record: Canonical?
    }

    let id: UUID
    let status: String
    let cursor: String
    let records: [Record]
}

private struct MeetingSyncChangePage: Decodable, Sendable {
    struct Change: Decodable, Sendable {
        struct Canonical: Decodable, Sendable {
            let vaultId: UUID?
            let projectId: UUID?
            let meetingId: UUID?
            let screenshotId: UUID?
            let parentProjectId: UUID?
            let name: String?
            let description: String?
            let projectType: String?
            let status: String?
            let duration: Double?
            let recordingStartedAt: Date?
            let createdAt: Date?
            let updatedAt: Date?
            let title: String?
            let document: String?
            let activeGeneration: String?
            let activeTranscriptGeneration: String?
            let summaryRevision: Int?
            let transcriptRevision: Int?
            let capturedAt: Date?
            let contentType: String?
            let ocrText: String?
            let caption: String?
        }

        let entity: String
        let entityId: UUID
        let action: String
        let revision: Int?
        let record: Canonical?
    }

    let items: [Change]
    let cursor: String
    let hasMore: Bool
}

private struct MeetingSyncTranscriptPage: Decodable, Sendable {
    struct Segment: Decodable, Sendable {
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

private struct MeetingSyncPullTarget: Sendable {
    let vaultId: UUID
    let connectionId: UUID
    let origin: URL
    let cursor: String?
    let bootstrapPending: Bool
}

private struct MeetingSyncVaultList: Decodable, Sendable {
    struct Vault: Decodable, Sendable {
        let vaultId: UUID
        let name: String
        let revision: Int
        let createdAt: Date
        let role: String
    }

    let items: [Vault]
}

private struct MeetingSyncScreenshotMetadata: Decodable, FetchableRecord, Sendable {
    let id: UUID
    let capturedAt: Date
    let ocrText: String?
    let caption: String?
    let syncUploadedConnectionId: UUID?
    let serverRevision: Int?
}

private struct MeetingSyncTranscriptSegment: Encodable {
    let segmentId: UUID
    let startTime: Date
    let endTime: Date?
    let text: String
    let isConfirmed: Bool
    let audioSource: String?
    let speakerLabel: String?
}

private struct MeetingSyncTranscriptChunk: Encodable {
    let segments: [MeetingSyncTranscriptSegment]
}

private struct MeetingSyncPayload: Sendable {
    let meeting: MeetingRecord
    let summary: SummaryRecord?
    let transcript: [TranscriptSegmentRecord]
    let screenshots: [MeetingSyncScreenshotMetadata]
    let screenshotsToUpload: [UUID]
    let connectionId: UUID
    let origin: URL
}

actor MeetingSyncWorker {
    private static let transcriptChunkSize = 500

    private let dbQueue: DatabaseQueue
    private let session: URLSession
    private let persistenceIsActive: @MainActor @Sendable () -> Bool
    private var drainTask: Task<Void, Never>?
    private var eventTasks: [UUID: Task<Void, Never>] = [:]

    init(
        dbQueue: DatabaseQueue,
        session: URLSession = .shared,
        persistenceIsActive: @escaping @MainActor @Sendable () -> Bool = { false }
    ) {
        self.dbQueue = dbQueue
        self.session = session
        self.persistenceIsActive = persistenceIsActive
    }

    func start(restored: Bool) async {
        do {
            if restored { try await MeetingSyncQueue.prepareRestore(dbQueue: dbQueue) }
            try await MeetingSyncQueue.reconcile(dbQueue: dbQueue)
            try await refreshCloudVaults()
        } catch {
            ErrorReportingService.capture(error, context: ["source": "meetingSyncReconcile"])
        }
        await restartEventStreams()
        drain()
    }

    func applicationBecameActive() async {
        do {
            try await waitUntilPersistenceIsIdle()
            try await MeetingSyncQueue.reconcile(dbQueue: dbQueue)
            try await refreshCloudVaults()
        } catch {
            ErrorReportingService.capture(error, context: ["source": "meetingSyncReconcile"])
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
                if await persistenceIsActive() {
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                try await drainVaultDeletions()
                try await pullRemoteChanges(bootstrapOnly: true)
                if let vaultJob = try await MeetingSyncQueue.claimVault(dbQueue: dbQueue) {
                    do {
                        let response = try await uploadVault(vaultJob)
                        try await MeetingSyncQueue.complete(vaultJob, response: response, dbQueue: dbQueue)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as MeetingSyncHTTPError {
                        if error.status == 409 {
                            try await MeetingSyncQueue.recordConflict(
                                vaultId: vaultJob.vaultId,
                                body: error.body,
                                dbQueue: dbQueue
                            )
                        }
                        try await MeetingSyncQueue.fail(
                            vaultJob,
                            code: Self.errorCode(error),
                            permanently: error.isPermanent,
                            dbQueue: dbQueue
                        )
                    } catch {
                        try await MeetingSyncQueue.fail(
                            vaultJob,
                            code: Self.errorCode(error),
                            permanently: false,
                            dbQueue: dbQueue
                        )
                    }
                    continue
                }
                guard let job = try await MeetingSyncQueue.claim(dbQueue: dbQueue) else {
                    try await pullRemoteChanges()
                    try await Task.sleep(for: .seconds(5))
                    continue
                }
                do {
                    if job.targetKind == "meetingDelete" {
                        let response = try await deleteMeeting(job)
                        try await MeetingSyncQueue.complete(job, response: response, dbQueue: dbQueue)
                    } else {
                        let response = try await uploadMeeting(job)
                        try await MeetingSyncQueue.complete(job, response: response, dbQueue: dbQueue)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as MeetingSyncHTTPError where error.isPermanent {
                    try await MeetingSyncQueue.block(
                        job,
                        code: Self.errorCode(error),
                        conflictJSON: error.status == 409 ? String(data: error.body, encoding: .utf8) : nil,
                        dbQueue: dbQueue
                    )
                } catch {
                    try await MeetingSyncQueue.fail(job, code: Self.errorCode(error), dbQueue: dbQueue)
                }
            } catch is CancellationError {
                return
            } catch {
                ErrorReportingService.capture(error, context: ["source": "meetingSyncDrain"])
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func uploadMeeting(_ job: MeetingSyncJob) async throws -> MeetingSyncTransactionResponse {
        guard let payload = try await loadPayload(job) else { throw MeetingSyncUnavailableError() }
        let base = "api/v1/vaults/\(job.vaultId.uuidString.lowercased())/meetings/\(job.meetingId.uuidString.lowercased())"
        for screenshotId in payload.screenshotsToUpload {
            guard let screenshot = try await dbQueue.read({ db in
                try MeetingScreenshotRecord.fetchOne(db, key: screenshotId)
            }), screenshot.meetingId == job.meetingId,
            screenshot.syncUploadedConnectionId != payload.connectionId else { continue }
            var request = try request(
                origin: payload.origin,
                path: "\(base)/screenshots/\(screenshot.id.uuidString.lowercased())/content",
                method: "PUT",
                body: screenshot.imageData,
                contentType: screenshot.mimeType
            )
            request.setValue(screenshot.capturedAt.ISO8601Format(), forHTTPHeaderField: "X-Dahlia-Captured-At")
            try await send(request, connectionId: payload.connectionId)
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE screenshots SET syncUploadedConnectionId = ? WHERE id = ?",
                    arguments: [payload.connectionId, screenshot.id]
                )
            }
        }

        let transcript = payload.transcript.map {
            MeetingSyncTranscriptSegment(
                segmentId: $0.id,
                startTime: $0.startTime,
                endTime: $0.endTime,
                text: $0.text,
                isConfirmed: $0.isConfirmed,
                audioSource: $0.audioSource,
                speakerLabel: $0.speakerLabel
            )
        }
        let transcriptData = try Self.encode(transcript)
        let generation = SHA256.hash(data: transcriptData).map { String(format: "%02x", $0) }.joined()
        for chunkIndex in stride(from: 0, to: transcript.count, by: Self.transcriptChunkSize) {
            let end = min(chunkIndex + Self.transcriptChunkSize, transcript.count)
            let body = try Self.encode(MeetingSyncTranscriptChunk(segments: Array(transcript[chunkIndex ..< end])))
            let request = try request(
                origin: payload.origin,
                path: "\(base)/transcripts/\(generation)/chunks/\(chunkIndex / Self.transcriptChunkSize)",
                method: "PUT",
                body: body,
                contentType: "application/json"
            )
            try await send(request, connectionId: payload.connectionId)
        }

        var operations: [[String: Any]] = []
        let meetingAction = payload.meeting.serverRevision == nil ? "create" : "update"
        var meetingData: [String: Any] = [
            "projectId": Self.json(payload.meeting.projectId),
            "name": payload.meeting.name,
            "description": payload.meeting.description,
            "status": payload.meeting.status.rawValue,
            "duration": Self.json(payload.meeting.duration),
            "recordingStartedAt": Self.json(payload.meeting.recordingStartedAt),
            "updatedAt": payload.meeting.updatedAt.ISO8601Format(),
            "screenshotIds": payload.screenshots.map { $0.id.uuidString.lowercased() },
        ]
        if meetingAction == "create" { meetingData["createdAt"] = payload.meeting.createdAt.ISO8601Format() }
        operations.append(Self.operation(
            transactionID: job.transactionId,
            index: operations.count,
            entity: "meeting",
            action: meetingAction,
            entityID: payload.meeting.id,
            baseRevision: payload.meeting.serverRevision,
            data: meetingData
        ))
        if let summary = payload.summary {
            operations.append(Self.operation(
                transactionID: job.transactionId,
                index: operations.count,
                entity: "summary",
                action: "upsert",
                entityID: payload.meeting.id,
                baseRevision: payload.meeting.summaryServerRevision,
                data: [
                    "title": summary.title,
                    "document": summary.document,
                    "createdAt": summary.createdAt.ISO8601Format(),
                ]
            ))
        } else if payload.meeting.summaryServerRevision > 0 {
            operations.append(Self.operation(
                transactionID: job.transactionId,
                index: operations.count,
                entity: "summary",
                action: "delete",
                entityID: payload.meeting.id,
                baseRevision: payload.meeting.summaryServerRevision,
                data: [:]
            ))
        }
        let activeGeneration = transcript.isEmpty ? nil : generation
        if activeGeneration != payload.meeting.transcriptServerGeneration {
            operations.append(Self.operation(
                transactionID: job.transactionId,
                index: operations.count,
                entity: "transcript",
                action: "replace",
                entityID: payload.meeting.id,
                baseRevision: payload.meeting.transcriptServerRevision,
                data: [
                    "generation": Self.json(activeGeneration),
                    "baseGeneration": Self.json(payload.meeting.transcriptServerGeneration),
                ]
            ))
        }
        for screenshot in payload.screenshots {
            operations.append(Self.operation(
                transactionID: job.transactionId,
                index: operations.count,
                entity: "screenshot",
                action: "upsert",
                entityID: screenshot.id,
                baseRevision: screenshot.serverRevision,
                data: [
                    "meetingId": payload.meeting.id.uuidString.lowercased(),
                    "capturedAt": screenshot.capturedAt.ISO8601Format(),
                    "ocrText": Self.json(screenshot.ocrText),
                    "caption": Self.json(screenshot.caption),
                ]
            ))
        }
        let transactionBody = try Self.transactionBody(
            id: job.transactionId,
            vaultID: job.vaultId,
            createdAt: job.transactionCreatedAt,
            operations: operations
        )
        do {
            let data = try await sendData(
                request(
                    origin: payload.origin,
                    path: "api/v1/transactions",
                    method: "POST",
                    body: transactionBody,
                    contentType: "application/json"
                ),
                connectionId: payload.connectionId
            )
            return try Self.decoder.decode(MeetingSyncTransactionResponse.self, from: data)
        } catch let error as MeetingSyncHTTPError where error.code == "screenshot_content_missing" {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE screenshots SET syncUploadedConnectionId = NULL WHERE meetingId = ?",
                    arguments: [job.meetingId]
                )
            }
            throw error
        }
    }

    private func uploadVault(_ job: VaultSyncJob) async throws -> MeetingSyncTransactionResponse {
        let payload = try await dbQueue.read { db -> (VaultRecord, [ProjectRecord], DahliaAccountConnectionRecord) in
            guard let vault = try VaultRecord.fetchOne(db, key: job.vaultId),
                  vault.syncEnabled,
                  vault.syncDeletionMode == nil,
                  let connectionId = vault.accountConnectionId,
                  vault.syncConfirmedConnectionId == connectionId,
                  let connection = try DahliaAccountConnectionRecord.fetchOne(db, key: connectionId)
            else { throw MeetingSyncUnavailableError() }
            return try (
                vault,
                ProjectRecord.filter(Column("vaultId") == job.vaultId)
                    .order(Column("parentProjectId"), Column("name"), Column("id"))
                    .fetchAll(db),
                connection
            )
        }
        guard let origin = URL(string: payload.2.origin) else { throw MeetingSyncUnavailableError() }
        var operations: [[String: Any]] = []
        var vaultData: [String: Any] = ["name": payload.0.name]
        let vaultAction = payload.0.serverRevision == nil ? "create" : "update"
        if vaultAction == "create" {
            vaultData["createdAt"] = payload.0.createdAt.ISO8601Format()
        } else {
            vaultData["projectIds"] = payload.1.map { $0.id.uuidString.lowercased() }
        }
        operations.append(Self.operation(
            transactionID: job.transactionId,
            index: operations.count,
            entity: "vault",
            action: vaultAction,
            entityID: payload.0.id,
            baseRevision: payload.0.serverRevision,
            data: vaultData
        ))
        for project in payload.1 {
            var data: [String: Any] = [
                "parentProjectId": Self.json(project.parentProjectId),
                "name": project.name,
                "description": project.description,
                "projectType": Self.json(project.projectType?.rawValue),
            ]
            let action = project.serverRevision == nil ? "create" : "update"
            if action == "create" { data["createdAt"] = project.createdAt.ISO8601Format() }
            operations.append(Self.operation(
                transactionID: job.transactionId,
                index: operations.count,
                entity: "project",
                action: action,
                entityID: project.id,
                baseRevision: project.serverRevision,
                data: data
            ))
        }
        let body = try Self.transactionBody(
            id: job.transactionId,
            vaultID: job.vaultId,
            createdAt: job.transactionCreatedAt,
            operations: operations
        )
        let data = try await sendData(
            request(
                origin: origin,
                path: "api/v1/transactions",
                method: "POST",
                body: body,
                contentType: "application/json"
            ),
            connectionId: payload.2.id
        )
        return try Self.decoder.decode(MeetingSyncTransactionResponse.self, from: data)
    }

    private func deleteMeeting(_ job: MeetingSyncJob) async throws -> MeetingSyncTransactionResponse {
        guard let connection = try await connection(vaultId: job.vaultId) else {
            throw MeetingSyncUnavailableError()
        }
        let body = try Self.transactionBody(
            id: job.transactionId,
            vaultID: job.vaultId,
            createdAt: job.transactionCreatedAt,
            operations: [Self.operation(
                transactionID: job.transactionId,
                index: 0,
                entity: "meeting",
                action: "delete",
                entityID: job.meetingId,
                baseRevision: job.baseRevision,
                data: [:]
            )]
        )
        let data = try await sendData(
            request(
                origin: connection.origin,
                path: "api/v1/transactions",
                method: "POST",
                body: body,
                contentType: "application/json"
            ),
            connectionId: connection.id
        )
        return try Self.decoder.decode(MeetingSyncTransactionResponse.self, from: data)
    }

    private func drainVaultDeletions() async throws {
        let deletions = try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT vaults.id, vaults.syncDeletionMode, vaults.syncDeletionConnectionId,
                       dahlia_account_connections.origin
                FROM vaults
                JOIN dahlia_account_connections
                    ON dahlia_account_connections.id = vaults.syncDeletionConnectionId
                WHERE vaults.syncDeletionMode IS NOT NULL AND vaults.syncDeletionApproved = 1
                """
            ).map { row in
                (
                    id: row["id"] as UUID,
                    mode: row["syncDeletionMode"] as String,
                    connectionId: row["syncDeletionConnectionId"] as UUID,
                    origin: row["origin"] as String
                )
            }
        }
        for deletion in deletions {
            guard let origin = URL(string: deletion.origin) else { continue }
            let path = "api/v1/vaults/\(deletion.id.uuidString.lowercased())"
            while try await send(
                request(origin: origin, path: path, method: "DELETE"),
                connectionId: deletion.connectionId,
                acceptedStatuses: [202, 204, 404]
            ) == 202 {}
            guard let mode = MeetingSyncDeletionMode(rawValue: deletion.mode) else {
                throw MeetingSyncUnavailableError()
            }
            try await MeetingSyncQueue.completeServerVaultDeletion(
                vaultId: deletion.id,
                mode: mode,
                dbQueue: dbQueue
            )
        }
    }

    private func restartEventStreams() async {
        for task in eventTasks.values {
            task.cancel()
        }
        eventTasks.removeAll()
        let connections = await (try? dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT dahlia_account_connections.id, dahlia_account_connections.origin
                FROM dahlia_account_connections
                """
            ).compactMap { row -> (UUID, URL)? in
                guard let url = URL(string: row["origin"] as String) else { return nil }
                return (row["id"], url)
            }
        }) ?? []
        for (connectionId, origin) in connections {
            eventTasks[connectionId] = Task { [weak self] in
                await self?.listenForInvalidations(connectionId: connectionId, origin: origin)
            }
        }
    }

    private func listenForInvalidations(connectionId: UUID, origin: URL) async {
        while !Task.isCancelled {
            do {
                var eventRequest = try request(origin: origin, path: "api/v1/events", method: "GET")
                let token = try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(connectionID: connectionId)
                eventRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                eventRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await session.bytes(for: eventRequest)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                for try await line in bytes.lines where line == "event: invalidation" {
                    try? await refreshCloudVaults(connectionId: connectionId)
                    drain()
                }
            } catch is CancellationError {
                return
            } catch {
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refreshCloudVaults(connectionId selectedConnectionId: UUID? = nil) async throws {
        let connections = try await dbQueue.read { db in
            try DahliaAccountConnectionRecord.fetchAll(db).compactMap { record -> (UUID, URL)? in
                guard selectedConnectionId == nil || record.id == selectedConnectionId,
                      let origin = URL(string: record.origin) else { return nil }
                return (record.id, origin)
            }
        }
        for (connectionId, origin) in connections {
            let data = try await sendData(
                request(origin: origin, path: "api/v1/vaults", method: "GET"),
                connectionId: connectionId
            )
            let remote = try Self.decoder.decode(MeetingSyncVaultList.self, from: data).items
                .filter { $0.role == "owner" }
            try await dbQueue.write { db in
                try db.execute(sql: "DELETE FROM cloud_vaults WHERE connectionId = ?", arguments: [connectionId])
                for vault in remote {
                    try CloudVaultRecord(
                        vaultId: vault.vaultId,
                        connectionId: connectionId,
                        name: vault.name,
                        createdAt: vault.createdAt,
                        revision: vault.revision
                    ).save(db)
                }
            }
        }
    }

    private func pullRemoteChanges(bootstrapOnly: Bool = false) async throws {
        let targets = try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT vaults.id, vaults.syncCursor, vaults.syncBootstrapPending,
                       dahlia_account_connections.id AS connectionId,
                       dahlia_account_connections.origin
                FROM vaults JOIN dahlia_account_connections
                  ON dahlia_account_connections.id = vaults.accountConnectionId
                WHERE vaults.syncEnabled = 1
                  AND vaults.syncDeletionMode IS NULL
                  AND vaults.syncConfirmedConnectionId = vaults.accountConnectionId
                  AND vaults.syncConflictJSON IS NULL
                  AND (? = 0 OR vaults.syncBootstrapPending = 1)
                  AND NOT EXISTS (SELECT 1 FROM vault_sync_jobs WHERE vaultId = vaults.id)
                  AND NOT EXISTS (SELECT 1 FROM meeting_sync_jobs WHERE vaultId = vaults.id)
                ORDER BY vaults.id
                """,
                arguments: [bootstrapOnly ? 1 : 0]
            ).compactMap { row -> MeetingSyncPullTarget? in
                guard let origin = URL(string: row["origin"] as String) else { return nil }
                return MeetingSyncPullTarget(
                    vaultId: row["id"],
                    connectionId: row["connectionId"],
                    origin: origin,
                    cursor: row["syncCursor"],
                    bootstrapPending: row["syncBootstrapPending"]
                )
            }
        }
        for target in targets {
            if target.bootstrapPending {
                let result = try await perform(
                    request(
                        origin: target.origin,
                        path: "api/v1/vaults/\(target.vaultId.uuidString.lowercased())",
                        method: "GET"
                    ),
                    connectionId: target.connectionId,
                    acceptedStatuses: [200, 404]
                )
                if result.status == 404 {
                    try await dbQueue.write { db in
                        try db.execute(
                            sql: "UPDATE vaults SET syncBootstrapPending = 0 WHERE id = ?",
                            arguments: [target.vaultId]
                        )
                    }
                    continue
                }
            }
            try await pullRemoteChanges(for: target)
        }
    }

    private func pullRemoteChanges(for target: MeetingSyncPullTarget) async throws {
        var cursor = target.cursor
        while true {
            var components = URLComponents()
            components.path = "/api/v1/vaults/\(target.vaultId.uuidString.lowercased())/changes"
            if let cursor { components.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
            guard let path = components.string else { throw URLError(.badURL) }
            let data = try await sendData(
                request(origin: target.origin, path: path, method: "GET"),
                connectionId: target.connectionId
            )
            let page = try Self.decoder.decode(MeetingSyncChangePage.self, from: data)
            let supplemental = try await loadSupplementalContent(page.items, target: target)
            try await apply(
                page.items,
                supplemental: supplemental,
                cursor: page.cursor,
                vaultId: target.vaultId,
                completesBootstrap: target.bootstrapPending && !page.hasMore
            )
            cursor = page.cursor
            if !page.hasMore { return }
        }
    }

    private struct SupplementalContent: Sendable {
        struct TranscriptSignature: Equatable, Sendable {
            let count: Int
            let maxId: UUID?
            let confirmedCount: Int
        }

        var screenshots: [UUID: Data] = [:]
        var transcripts: [UUID: [MeetingSyncTranscriptPage.Segment]] = [:]
        var transcriptSignatures: [UUID: TranscriptSignature] = [:]
    }

    private func loadSupplementalContent(
        _ changes: [MeetingSyncChangePage.Change],
        target: MeetingSyncPullTarget
    ) async throws -> SupplementalContent {
        var content = SupplementalContent()
        for change in changes where change.action == "upsert" {
            guard let record = change.record else { continue }
            if change.entity == "screenshot", let meetingId = record.meetingId {
                content.screenshots[change.entityId] = try await sendData(
                    request(
                        origin: target.origin,
                        path: "api/v1/vaults/\(target.vaultId.uuidString.lowercased())/meetings/\(meetingId.uuidString.lowercased())/screenshots/\(change.entityId.uuidString.lowercased())/content",
                        method: "GET"
                    ),
                    connectionId: target.connectionId
                )
            } else if change.entity == "transcript" {
                content.transcriptSignatures[change.entityId] = try await transcriptSignature(
                    meetingId: change.entityId
                )
                content.transcripts[change.entityId] = try await loadTranscript(
                    vaultId: target.vaultId,
                    meetingId: change.entityId,
                    target: target
                )
            }
        }
        return content
    }

    private func transcriptSignature(meetingId: UUID) async throws -> SupplementalContent.TranscriptSignature {
        try await dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT count(*) AS segmentCount, max(id) AS maxSegmentId,
                    sum(CASE WHEN isConfirmed = 1 THEN 1 ELSE 0 END) AS confirmedCount
                FROM transcript_segments WHERE meetingId = ?
                """,
                arguments: [meetingId]
            )
            return SupplementalContent.TranscriptSignature(
                count: row?["segmentCount"] ?? 0,
                maxId: row?["maxSegmentId"],
                confirmedCount: row?["confirmedCount"] ?? 0
            )
        }
    }

    private func loadTranscript(
        vaultId: UUID,
        meetingId: UUID,
        target: MeetingSyncPullTarget
    ) async throws -> [MeetingSyncTranscriptPage.Segment] {
        var segments: [MeetingSyncTranscriptPage.Segment] = []
        var cursor: String?
        repeat {
            var components = URLComponents()
            components.path = "/api/v1/vaults/\(vaultId.uuidString.lowercased())/meetings/\(meetingId.uuidString.lowercased())/transcript"
            if let cursor { components.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
            guard let path = components.string else { throw URLError(.badURL) }
            let data = try await sendData(
                request(origin: target.origin, path: path, method: "GET"),
                connectionId: target.connectionId
            )
            let page = try Self.decoder.decode(MeetingSyncTranscriptPage.self, from: data)
            segments.append(contentsOf: page.items)
            cursor = page.nextCursor
        } while cursor != nil
        return segments
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func apply(
        _ changes: [MeetingSyncChangePage.Change],
        supplemental: SupplementalContent,
        cursor: String,
        vaultId: UUID,
        completesBootstrap: Bool
    ) async throws {
        try await dbQueue.write { db in
            guard try !(Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (SELECT 1 FROM vault_sync_jobs WHERE vaultId = ?)
                    OR EXISTS (SELECT 1 FROM meeting_sync_jobs WHERE vaultId = ?)
                """,
                arguments: [vaultId, vaultId]
            ) ?? false) else { throw MeetingSyncUnavailableError() }
            for (meetingId, expected) in supplemental.transcriptSignatures {
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT count(*) AS segmentCount, max(id) AS maxSegmentId,
                        sum(CASE WHEN isConfirmed = 1 THEN 1 ELSE 0 END) AS confirmedCount
                    FROM transcript_segments WHERE meetingId = ?
                    """,
                    arguments: [meetingId]
                )
                let current = SupplementalContent.TranscriptSignature(
                    count: row?["segmentCount"] ?? 0,
                    maxId: row?["maxSegmentId"],
                    confirmedCount: row?["confirmedCount"] ?? 0
                )
                guard current == expected else { throw MeetingSyncUnavailableError() }
            }
            try db.execute(sql: "INSERT OR IGNORE INTO sync_apply_context(active) VALUES(1)")
            defer { try? db.execute(sql: "DELETE FROM sync_apply_context") }
            for change in changes {
                if change.action == "delete" {
                    switch change.entity {
                    case "project":
                        try db.execute(sql: "DELETE FROM projects WHERE id = ? AND vaultId = ?", arguments: [change.entityId, vaultId])
                    case "meeting":
                        try db.execute(sql: "DELETE FROM meetings WHERE id = ? AND vaultId = ?", arguments: [change.entityId, vaultId])
                    case "screenshot":
                        try db.execute(sql: "DELETE FROM screenshots WHERE id = ?", arguments: [change.entityId])
                    default:
                        break
                    }
                    continue
                }
                if change.action == "reset", change.entity == "vault" {
                    try db.execute(
                        sql: "UPDATE vaults SET syncEnabled = 0, serverRevision = NULL, syncCursor = NULL WHERE id = ?",
                        arguments: [vaultId]
                    )
                    continue
                }
                guard let record = change.record else { continue }
                switch change.entity {
                case "vault":
                    guard let name = record.name else { continue }
                    try db.execute(
                        sql: "UPDATE vaults SET name = ?, serverRevision = ? WHERE id = ?",
                        arguments: [name, change.revision, vaultId]
                    )
                case "project":
                    guard let name = record.name, let createdAt = record.createdAt else { continue }
                    let project = ProjectRecord(
                        id: change.entityId,
                        vaultId: vaultId,
                        parentProjectId: record.parentProjectId,
                        name: name,
                        createdAt: createdAt,
                        description: record.description ?? "",
                        projectType: record.projectType.flatMap(ProjectType.init(rawValue:)),
                        serverRevision: change.revision
                    )
                    try project.save(db)
                case "meeting":
                    guard let name = record.name, let status = record.status,
                          let createdAt = record.createdAt, let updatedAt = record.updatedAt else { continue }
                    try db.execute(
                        sql: """
                        INSERT INTO meetings (
                            id, vaultId, projectId, name, description, status, duration,
                            createdAt, updatedAt, recordingStartedAt, serverRevision,
                            summaryServerRevision, transcriptServerRevision, transcriptServerGeneration
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET projectId = excluded.projectId,
                            name = excluded.name, description = excluded.description,
                            status = excluded.status, duration = excluded.duration,
                            createdAt = excluded.createdAt, updatedAt = excluded.updatedAt,
                            recordingStartedAt = excluded.recordingStartedAt,
                            serverRevision = excluded.serverRevision,
                            summaryServerRevision = excluded.summaryServerRevision,
                            transcriptServerRevision = excluded.transcriptServerRevision,
                            transcriptServerGeneration = excluded.transcriptServerGeneration
                        """,
                        arguments: [
                            change.entityId, vaultId, record.projectId, name, record.description ?? "", status,
                            record.duration, createdAt, updatedAt, record.recordingStartedAt, change.revision,
                            record.summaryRevision ?? 0, record.transcriptRevision ?? 0,
                            record.activeTranscriptGeneration,
                        ]
                    )
                case "summary":
                    if let title = record.title, let document = record.document, let createdAt = record.createdAt {
                        try SummaryRecord(
                            meetingId: change.entityId,
                            title: title,
                            document: document,
                            createdAt: createdAt,
                            serverRevision: change.revision ?? 0
                        ).save(db)
                    } else {
                        try db.execute(sql: "DELETE FROM summaries WHERE meetingId = ?", arguments: [change.entityId])
                    }
                    try db.execute(
                        sql: "UPDATE meetings SET summaryServerRevision = ? WHERE id = ?",
                        arguments: [change.revision ?? 0, change.entityId]
                    )
                case "transcript":
                    try db.execute(sql: "DELETE FROM transcript_segments WHERE meetingId = ?", arguments: [change.entityId])
                    for segment in supplemental.transcripts[change.entityId, default: []] {
                        try db.execute(
                            sql: """
                            INSERT INTO transcript_segments (
                                id, meetingId, startTime, endTime, text, isConfirmed, audioSource, speakerLabel
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            arguments: [
                                segment.segmentId, change.entityId, segment.startTime, segment.endTime,
                                segment.text, segment.isConfirmed, segment.audioSource, segment.speakerLabel,
                            ]
                        )
                    }
                    try db.execute(
                        sql: "UPDATE meetings SET transcriptServerRevision = ?, transcriptServerGeneration = ? WHERE id = ?",
                        arguments: [change.revision ?? 0, record.activeGeneration, change.entityId]
                    )
                case "screenshot":
                    guard let meetingId = record.meetingId, let capturedAt = record.capturedAt,
                          let contentType = record.contentType,
                          let imageData = supplemental.screenshots[change.entityId] else { continue }
                    try db.execute(
                        sql: """
                        INSERT INTO screenshots (
                            id, meetingId, capturedAt, imageData, mimeType, ocrText, caption,
                            syncUploadedConnectionId, serverRevision
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?)
                        ON CONFLICT(id) DO UPDATE SET capturedAt = excluded.capturedAt,
                            imageData = excluded.imageData, mimeType = excluded.mimeType,
                            ocrText = excluded.ocrText, caption = excluded.caption,
                            serverRevision = excluded.serverRevision
                        """,
                        arguments: [
                            change.entityId, meetingId, capturedAt, imageData, contentType,
                            record.ocrText, record.caption, change.revision,
                        ]
                    )
                default:
                    continue
                }
            }
            try db.execute(
                sql: """
                UPDATE vaults SET syncCursor = ?,
                    syncBootstrapPending = CASE WHEN ? THEN 0 ELSE syncBootstrapPending END
                WHERE id = ?
                """,
                arguments: [cursor, completesBootstrap, vaultId]
            )
        }
    }

    private func loadPayload(_ job: MeetingSyncJob) async throws -> MeetingSyncPayload? {
        try await dbQueue.read { db in
            guard let vault = try VaultRecord.fetchOne(db, key: job.vaultId) else { return nil }
            guard vault.syncEnabled,
                  vault.syncDeletionMode == nil,
                  let connectionId = vault.accountConnectionId,
                  vault.syncConfirmedConnectionId == connectionId,
                  let connection = try DahliaAccountConnectionRecord.fetchOne(db, key: connectionId),
                  let origin = URL(string: connection.origin) else { throw MeetingSyncUnavailableError() }
            guard let meeting = try MeetingRecord.fetchOne(db, key: job.meetingId) else { return nil }
            let screenshots = try MeetingScreenshotRecord
                .filter(Column("meetingId") == job.meetingId)
                .select(
                    Column("id"),
                    Column("capturedAt"),
                    Column("ocrText"),
                    Column("caption"),
                    Column("syncUploadedConnectionId"),
                    Column("serverRevision")
                )
                .order(Column("capturedAt"), Column("id"))
                .asRequest(of: MeetingSyncScreenshotMetadata.self)
                .fetchAll(db)
            return try MeetingSyncPayload(
                meeting: meeting,
                summary: SummaryRecord.fetchOne(db, key: job.meetingId),
                transcript: TranscriptSegmentRecord
                    .filter(Column("meetingId") == job.meetingId)
                    .order(Column("startTime"), Column("id"))
                    .fetchAll(db),
                screenshots: screenshots,
                screenshotsToUpload: screenshots.compactMap {
                    $0.syncUploadedConnectionId == connectionId ? nil : $0.id
                },
                connectionId: connectionId,
                origin: origin
            )
        }
    }

    private func connection(vaultId: UUID) async throws -> (id: UUID, origin: URL)? {
        try await dbQueue.read { db in
            guard let vault = try VaultRecord.fetchOne(db, key: vaultId),
                  let id = vault.accountConnectionId,
                  vault.syncConfirmedConnectionId == id,
                  let record = try DahliaAccountConnectionRecord.fetchOne(db, key: id),
                  let origin = URL(string: record.origin) else { return nil }
            return (id, origin)
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

    @discardableResult
    private func send(
        _ unsignedRequest: URLRequest,
        connectionId: UUID,
        acceptedStatuses: Set<Int> = [200, 201, 204]
    ) async throws -> Int {
        try await perform(unsignedRequest, connectionId: connectionId, acceptedStatuses: acceptedStatuses).status
    }

    private func sendData(
        _ unsignedRequest: URLRequest,
        connectionId: UUID,
        acceptedStatuses: Set<Int> = [200, 201, 204]
    ) async throws -> Data {
        try await perform(unsignedRequest, connectionId: connectionId, acceptedStatuses: acceptedStatuses).data
    }

    private func perform(
        _ unsignedRequest: URLRequest,
        connectionId: UUID,
        acceptedStatuses: Set<Int>
    ) async throws -> (data: Data, status: Int) {
        var forceRefresh = false
        for attempt in 0 ... 1 {
            try await waitUntilPersistenceIsIdle()
            var request = unsignedRequest
            let token = try await DahliaCloudTokenServiceRegistry.shared.validAccessToken(
                connectionID: connectionId,
                forceRefresh: forceRefresh
            )
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if acceptedStatuses.contains(http.statusCode) { return (data, http.statusCode) }
            if http.statusCode == 401, attempt == 0 {
                forceRefresh = true
                continue
            }
            let code = (try? JSONDecoder().decode(MeetingSyncErrorResponse.self, from: data))?.error
            throw MeetingSyncHTTPError(status: http.statusCode, code: code, body: data)
        }
        throw MeetingSyncHTTPError(status: 401, code: nil, body: Data())
    }

    private func waitUntilPersistenceIsIdle() async throws {
        while true {
            if await persistenceIsActive() {
                try await Task.sleep(for: .seconds(1))
                continue
            }
            guard try await MeetingSyncQueue.batchPersistenceIsActive(dbQueue: dbQueue) else { return }
            try await Task.sleep(for: .seconds(1))
        }
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw try DecodingError.dataCorruptedError(
                in: decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date"
            )
        }
        return decoder
    }()

    private static func transactionBody(
        id: String,
        vaultID: UUID,
        createdAt: Date,
        operations: [[String: Any]]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "id": id,
            "vaultId": vaultID.uuidString.lowercased(),
            "createdAt": createdAt.ISO8601Format(),
            "operations": operations,
        ], options: [.sortedKeys])
    }

    private static func operation(
        transactionID: String,
        index: Int,
        entity: String,
        action: String,
        entityID: UUID,
        baseRevision: Int?,
        data: [String: Any]
    ) -> [String: Any] {
        [
            "id": operationID(transactionID: transactionID, index: index),
            "entity": entity,
            "action": action,
            "entityId": entityID.uuidString.lowercased(),
            "baseRevision": json(baseRevision),
            "data": data,
        ]
    }

    private static func operationID(transactionID: String, index: Int) -> String {
        guard var bytes = UUID(uuidString: transactionID)?.uuid else { return transactionID }
        withUnsafeMutableBytes(of: &bytes) { buffer in
            buffer[12] = UInt8(truncatingIfNeeded: index >> 24)
            buffer[13] = UInt8(truncatingIfNeeded: index >> 16)
            buffer[14] = UInt8(truncatingIfNeeded: index >> 8)
            buffer[15] = UInt8(truncatingIfNeeded: index)
        }
        return UUID(uuid: bytes).uuidString.lowercased()
    }

    private static func json(_ value: UUID?) -> Any { value?.uuidString.lowercased() ?? NSNull() }
    private static func json(_ value: Date?) -> Any { value?.ISO8601Format() ?? NSNull() }
    private static func json(_ value: String?) -> Any { value ?? NSNull() }
    private static func json(_ value: Double?) -> Any { value ?? NSNull() }
    private static func json(_ value: Int?) -> Any { value ?? NSNull() }

    private static func errorCode(_ error: Error) -> String {
        if let error = error as? MeetingSyncHTTPError { return "http_\(error.status)" }
        if error is MeetingSyncUnavailableError { return "connection_unavailable" }
        if error is DahliaCloudError { return "authentication" }
        if error is URLError { return "network" }
        return "sync_failed"
    }
}

private struct MeetingSyncHTTPError: Error {
    let status: Int
    let code: String?
    let body: Data

    var isPermanent: Bool {
        code != "screenshot_content_missing" && [400, 409, 411, 413, 415, 422].contains(status)
    }
}

private struct MeetingSyncErrorResponse: Decodable {
    let error: String
}

struct MeetingSyncUnavailableError: Error {}
