import CryptoKit
import Foundation
import GRDB

private struct MeetingSyncManifestBody: Encodable {
    struct Summary: Encodable {
        let title: String
        let document: String
        let createdAt: Date
    }

    struct Screenshot: Encodable, Sendable {
        let screenshotId: UUID
        let capturedAt: Date
        let ocrText: String?
        let caption: String?
    }

    let name: String
    let projectId: UUID?
    let description: String
    let status: String
    let duration: TimeInterval?
    let recordingStartedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let summary: Summary?
    let activeTranscriptGeneration: String?
    let screenshots: [Screenshot]
}

private struct VaultSyncManifestBody: Encodable {
    struct Project: Encodable {
        let projectId: UUID
        let parentProjectId: UUID?
        let name: String
        let description: String
        let projectType: ProjectType?
        let revision: Int
        let createdAt: Date
    }

    let name: String
    let createdAt: Date
    let projects: [Project]
}

private struct MeetingSyncScreenshotMetadata: Decodable, FetchableRecord, Sendable {
    let id: UUID
    let capturedAt: Date
    let ocrText: String?
    let caption: String?
    let syncUploadedConnectionId: UUID?
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
        } catch {
            ErrorReportingService.capture(error, context: ["source": "meetingSyncReconcile"])
        }
        drain()
    }

    func applicationBecameActive() async {
        do {
            try await waitUntilPersistenceIsIdle()
            try await MeetingSyncQueue.reconcile(dbQueue: dbQueue)
        } catch {
            ErrorReportingService.capture(error, context: ["source": "meetingSyncReconcile"])
        }
        drain()
    }

    func stop() async {
        drainTask?.cancel()
        await drainTask?.value
        drainTask = nil
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
                if let vaultJob = try await MeetingSyncQueue.claimVault(dbQueue: dbQueue) {
                    do {
                        try await uploadVault(vaultJob)
                        try await MeetingSyncQueue.complete(vaultJob, dbQueue: dbQueue)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as MeetingSyncHTTPError {
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
                    try await Task.sleep(for: .seconds(5))
                    continue
                }
                do {
                    if job.targetKind == "meetingDelete" {
                        try await deleteMeeting(job)
                    } else {
                        try await uploadMeeting(job)
                    }
                    try await MeetingSyncQueue.complete(job, dbQueue: dbQueue)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as MeetingSyncHTTPError where error.isPermanent {
                    try await MeetingSyncQueue.block(job, code: Self.errorCode(error), dbQueue: dbQueue)
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

    private func uploadMeeting(_ job: MeetingSyncJob) async throws {
        guard let payload = try await loadPayload(job) else { return }
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

        let manifest = MeetingSyncManifestBody(
            name: payload.meeting.name,
            projectId: payload.meeting.projectId,
            description: payload.meeting.description,
            status: payload.meeting.status.rawValue,
            duration: payload.meeting.duration,
            recordingStartedAt: payload.meeting.recordingStartedAt,
            createdAt: payload.meeting.createdAt,
            updatedAt: payload.meeting.updatedAt,
            summary: payload.summary.map {
                MeetingSyncManifestBody.Summary(title: $0.title, document: $0.document, createdAt: $0.createdAt)
            },
            activeTranscriptGeneration: transcript.isEmpty ? nil : generation,
            screenshots: payload.screenshots.map {
                MeetingSyncManifestBody.Screenshot(
                    screenshotId: $0.id,
                    capturedAt: $0.capturedAt,
                    ocrText: $0.ocrText,
                    caption: $0.caption
                )
            }
        )
        let manifestBody = try Self.encode(manifest)
        do {
            try await send(
                request(
                    origin: payload.origin,
                    path: "\(base)/manifest",
                    method: "PUT",
                    body: manifestBody,
                    contentType: "application/json"
                ),
                connectionId: payload.connectionId
            )
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

    private func uploadVault(_ job: VaultSyncJob) async throws {
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
        let body = VaultSyncManifestBody(
            name: payload.0.name,
            createdAt: payload.0.createdAt,
            projects: payload.1.map {
                VaultSyncManifestBody.Project(
                    projectId: $0.id,
                    parentProjectId: $0.parentProjectId,
                    name: $0.name,
                    description: $0.description,
                    projectType: $0.projectType,
                    revision: $0.revision,
                    createdAt: $0.createdAt
                )
            }
        )
        try await send(
            request(
                origin: origin,
                path: "api/v1/vaults/\(job.vaultId.uuidString.lowercased())/manifest",
                method: "PUT",
                body: Self.encode(body),
                contentType: "application/json"
            ),
            connectionId: payload.2.id
        )
    }

    private func deleteMeeting(_ job: MeetingSyncJob) async throws {
        guard let connection = try await connection(vaultId: job.vaultId) else {
            throw MeetingSyncUnavailableError()
        }
        let path = "api/v1/vaults/\(job.vaultId.uuidString.lowercased())/meetings/\(job.meetingId.uuidString.lowercased())"
        while try await send(
            request(origin: connection.origin, path: path, method: "DELETE"),
            connectionId: connection.id,
            acceptedStatuses: [202, 204, 404]
        ) == 202 {}
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
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE vaults SET syncDeletionMode = NULL, syncDeletionApproved = 0,
                        syncDeletionConnectionId = NULL
                    WHERE id = ?
                    """,
                    arguments: [deletion.id]
                )
                if deletion.mode == MeetingSyncDeletionMode.replaceAfterRestore.rawValue {
                    try db.execute(
                        sql: """
                        INSERT INTO vault_sync_jobs(vaultId) VALUES(?)
                        ON CONFLICT(vaultId) DO UPDATE SET generation = generation + 1,
                            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'),
                            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL,
                            updatedAt = unixepoch('subsec');
                        INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind)
                        SELECT vaultId, id, 'upload' FROM meetings WHERE vaultId = ?
                        ON CONFLICT(targetKind, meetingId) DO UPDATE SET generation = generation + 1,
                            status = 'pending', attempts = 0, availableAt = unixepoch('subsec'),
                            claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = NULL,
                            updatedAt = unixepoch('subsec')
                        """,
                        arguments: [deletion.id, deletion.id]
                    )
                }
            }
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
                    Column("syncUploadedConnectionId")
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
            if acceptedStatuses.contains(http.statusCode) { return http.statusCode }
            if http.statusCode == 401, attempt == 0 {
                forceRefresh = true
                continue
            }
            let code = (try? JSONDecoder().decode(MeetingSyncErrorResponse.self, from: data))?.error
            throw MeetingSyncHTTPError(status: http.statusCode, code: code)
        }
        throw MeetingSyncHTTPError(status: 401, code: nil)
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

    var isPermanent: Bool {
        code != "screenshot_content_missing" && [400, 409, 411, 413, 415, 422].contains(status)
    }
}

private struct MeetingSyncErrorResponse: Decodable {
    let error: String
}

private struct MeetingSyncUnavailableError: Error {}
