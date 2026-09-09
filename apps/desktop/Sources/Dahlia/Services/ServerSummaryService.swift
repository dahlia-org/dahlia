import DahliaRuntimeSupport
import DahliaServerAPI
import Foundation
import GRDB

actor ServerSummaryService {
    static let shared = ServerSummaryService()
    private let client: SyncAPIClient
    private let synchronize: @Sendable (Target, DatabaseQueue) async throws -> Void

    struct Target: Equatable, Sendable {
        let vaultID: UUID
        let meetingID: UUID
        let connectionID: UUID
        let origin: String
    }

    struct Job: Decodable, Sendable {
        let id: String
        let status: String
        let error: String?
        let stage: String?
        var isActive: Bool { status == "pending" || status == "processing" }
        var isRetryable: Bool { status == "failed" || status == "cancelled" }
        var isTerminal: Bool { isRetryable || status == "succeeded" }
    }

    struct Model: Decodable, Identifiable, Sendable {
        struct Effort: Decodable, Sendable { let effort: String }
        let slug: String
        let displayName: String
        let supportedReasoningLevels: [Effort]
        let defaultReasoningLevel: String?
        let inputModalities: [String]?
        let supportsJSONSchema: Bool?
        let summaryMethods: [String]?
        var supportsStructuredSummary: Bool { supportsJSONSchema == true }
        var supportsAudioSummary: Bool { slug.hasPrefix("gemini-") && inputModalities?.contains("audio") == true }
        func supportsSummary(method: String) -> Bool {
            let source = method == "audio" ? "audio" : "transcript"
            return supportsStructuredSummary && (summaryMethods?.contains(source) ?? true)
                && (source != "audio" || supportsAudioSummary)
        }

        var id: String { slug }
        private enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case supportedReasoningLevels = "supported_reasoning_levels"
            case defaultReasoningLevel = "default_reasoning_level"
            case inputModalities = "input_modalities"
            case supportsJSONSchema = "supports_json_schema"
            case summaryMethods = "summary_methods"
        }
    }

    private struct ModelList: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
        let models: [Model]
    }

    private struct Response: Decodable { let job: Job? }

    struct RecordingPair: Codable, Sendable {
        let micFileId: String?
        let systemFileId: String?
        enum CodingKeys: String, CodingKey { case micFileId, systemFileId }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(micFileId, forKey: .micFileId)
            try container.encode(systemFileId, forKey: .systemFileId)
        }
    }

    struct Input: Codable, Sendable {
        let type: String
        var version: String?
        var recordings: [RecordingPair]?
        var transcriptionModel: String?
    }

    struct Request: Codable, Sendable {
        let id: String
        let input: Input
        let model: String
        let detailLevel: String
        let summaryLanguage: String
    }

    enum Failure: LocalizedError {
        case unavailable, syncPending
        case generationFailed(String?)
        var errorDescription: String? {
            switch self {
            case .unavailable: L10n.serverSummaryUnavailable
            case .syncPending: L10n.serverSummarySyncPending
            case let .generationFailed(code):
                code == "summary_input_changed" ? L10n.serverSummaryInputChanged : L10n.serverSummaryFailed + (code.map { " (\($0))" } ?? "")
            }
        }
    }

    init(
        client: SyncAPIClient = SyncAPIClient(session: .shared),
        synchronize: (@Sendable (Target, DatabaseQueue) async throws -> Void)? = nil
    ) {
        self.client = client
        self.synchronize = synchronize ?? { target, queue in
            let worker = SyncWorker(dbQueue: queue, session: client.session, apiClient: client)
            try await worker.synchronizeForTransfer(vaultId: target.vaultID, connectionId: target.connectionID)
        }
    }

    func target(meetingID: UUID, dbQueue: DatabaseQueue) async throws -> Target? {
        try await dbQueue.read { db in
            guard let meeting = try MeetingRecord.fetchOne(db, key: meetingID),
                  let vault = try VaultRecord.fetchOne(db, key: meeting.vaultId) else { throw Failure.unavailable }
            guard let connectionID = vault.accountConnectionId else { return nil }
            guard let origin = try String.fetchOne(db, sql: "SELECT origin FROM dahlia_account_connections WHERE id = ?", arguments: [connectionID])
            else {
                throw Failure.unavailable
            }
            return Target(vaultID: vault.id, meetingID: meetingID, connectionID: connectionID, origin: origin)
        }
    }

    func methods(connectionID: UUID, origin: String) async throws -> [String] {
        guard let origin = URL(string: origin) else { throw URLError(.badURL) }
        let data = try await client.data(origin: origin, connectionId: connectionID, maximumBytes: 8192) {
            try await $0.getCapabilities().ok.body.json
        }
        let summary = try JSONDecoder().decode(ServerCapabilities.self, from: data).meetingSummaryGeneration
        guard let summary, summary.version == 1 else { return [] }
        return summary.sources
    }

    func models(connectionID: UUID, origin: String) async throws -> [Model] {
        let data = try await client.data(
            for: request(origin: origin, path: "/api/v1/models"),
            connectionId: connectionID,
            maximumBytes: 4 * 1024 * 1024
        )
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        return list.data.filter { $0.id != "codex-auto-review" }
            .compactMap { entry in list.models.first { $0.id == entry.id } }
    }

    func status(_ target: Target, id: UUID? = nil) async throws -> Job? {
        guard let origin = URL(string: target.origin) else { throw URLError(.badURL) }
        do {
            let data: Data = if let id {
                try await client.data(origin: origin, connectionId: target.connectionID, maximumBytes: 65536) {
                    try await $0.getSummaryJob(path: .init(meetingId: target.meetingID.uuidString.lowercased(), jobId: id.uuidString.lowercased())).ok
                        .body.json
                }
            } else {
                try await client.data(origin: origin, connectionId: target.connectionID, maximumBytes: 65536) {
                    try await $0.getLatestSummaryJob(path: .init(meetingId: target.meetingID.uuidString.lowercased())).ok.body.json
                }
            }
            return try JSONDecoder().decode(Response.self, from: data).job
        } catch let error as SyncHTTPError where error.status == 404 && error.code == "summary_job_not_found" {
            return nil
        }
    }

    func start(_ target: Target, id: UUID, detail: String?, outputLanguage: SummaryLanguage? = nil) async throws -> Job? {
        typealias Body = Operations.StartSummaryJob.Input.Body.JsonPayload.Value2Payload
        let body = Body(
            id: id.uuidString.lowercased(),
            detail: detail.flatMap { Body.DetailPayload(rawValue: SummaryDetailLevel.fromPersistedValue($0).rawValue) },
            outputLanguage: outputLanguage.flatMap { Body.OutputLanguagePayload(rawValue: $0.rawValue) }
        )
        return try await start(target, body: .init(value2: body))
    }

    func start(_ target: Target, request body: Request) async throws -> Job? {
        typealias Body = Operations.StartSummaryJob.Input.Body.JsonPayload.Value1Payload
        guard let detail = Body.DetailPayload(rawValue: SummaryDetailLevel.fromPersistedValue(body.detailLevel).rawValue),
              let language = Body.OutputLanguagePayload(rawValue: body.summaryLanguage) else { throw Failure.unavailable }
        let input = try JSONDecoder().decode(Body.InputPayload.self, from: JSONEncoder().encode(body.input))
        return try await start(
            target,
            body: .init(value1: Body(id: body.id, input: input, model: body.model, detail: detail, outputLanguage: language))
        )
    }

    private func start(_ target: Target, body: Operations.StartSummaryJob.Input.Body.JsonPayload) async throws -> Job? {
        guard let origin = URL(string: target.origin) else { throw URLError(.badURL) }
        let data = try await client.data(origin: origin, connectionId: target.connectionID, maximumBytes: 65536) {
            try await $0.startSummaryJob(path: .init(meetingId: target.meetingID.uuidString.lowercased()), body: .json(body)).accepted.body.json
        }
        return try JSONDecoder().decode(Response.self, from: data).job
    }

    func cancel(_ target: Target, id: UUID) async throws -> Job? {
        guard let origin = URL(string: target.origin) else { throw URLError(.badURL) }
        let data = try await client.data(origin: origin, connectionId: target.connectionID, maximumBytes: 65536) {
            try await $0.cancelSummaryJob(path: .init(meetingId: target.meetingID.uuidString.lowercased(), jobId: id.uuidString.lowercased())).ok.body
                .json
        }
        return try JSONDecoder().decode(Response.self, from: data).job
    }

    func retry(_ target: Target, previousID: String, id: UUID) async throws -> Job? {
        guard UUID(uuidString: previousID) != nil, let origin = URL(string: target.origin) else { throw Failure.unavailable }
        let data = try await client.data(origin: origin, connectionId: target.connectionID, maximumBytes: 65536) {
            try await $0.retrySummaryJob(
                path: .init(meetingId: target.meetingID.uuidString.lowercased(), jobId: previousID),
                body: .json(.init(id: id.uuidString.lowercased()))
            ).accepted.body.json
        }
        return try JSONDecoder().decode(Response.self, from: data).job
    }

    func generate(
        _ target: Target,
        id: UUID,
        detail: String?,
        dbQueue: DatabaseQueue,
        processing: RecordingProcessing? = nil,
        onPrepared: @Sendable (Request) async throws -> Void = { _ in },
        onStage: @MainActor @Sendable (String) async -> Void = { _ in }
    ) async throws {
        guard try await !methods(connectionID: target.connectionID, origin: target.origin).isEmpty else { throw Failure.unavailable }
        let sessionIDs: [UUID] = if let processing {
            processing.sessionIDs
        } else {
            try await dbQueue.read { db in
                try RecordingSessionRecord.filter(Column("meetingId") == target.meetingID)
                    .filter(Column("transcriptionMode") == "batch" && Column("batchDiscardedAt") == nil)
                    .order(Column("startedAt").asc).fetchAll(db).map(\.id)
            }
        }
        await onStage("uploading")
        try await awaitSynchronization(target, dbQueue: dbQueue)
        var job = try await status(target, id: id)
        if job == nil, let previousID = processing?.retryOf {
            job = try await retry(target, previousID: previousID, id: id)
        }
        if job == nil {
            let body: Request
            if let saved = processing?.serverRequest {
                body = saved
            } else {
                let settings: ServerAccountSettings
                if let captured = processing?.serverSettings {
                    settings = captured
                } else {
                    guard let origin = URL(string: target.origin) else { throw URLError(.badURL) }
                    let data = try await client.data(origin: origin, connectionId: target.connectionID, maximumBytes: 8192) {
                        try await $0.getSettings().ok.body.json
                    }
                    guard let saved = try JSONDecoder().decode(ServerAccountSettings.Response.self, from: data).settings
                    else { throw Failure.unavailable }
                    settings = saved
                }
                let method = processing?.method ?? RecordingProcessingMethod(rawValue: settings.summary?.method ?? "transcript") ?? .transcript
                let input: Input
                if method == .transcript {
                    guard let version = try await dbQueue.read({ db in try TranscriptRecord.current(target.meetingID, in: db)?.version }) else {
                        throw Failure.syncPending
                    }
                    input = Input(type: "transcript", version: String(version))
                } else {
                    try await awaitRecordingUploads(target, sessionIDs: sessionIDs, dbQueue: dbQueue)
                    let numbers = try await dbQueue.read { db in
                        try sessionIDs.map { id in
                            guard let number = try RecordingArchiveRecord.fetchOne(db, key: id)?.number else { throw Failure.syncPending }
                            return number
                        }
                    }
                    input = try await Input(
                        type: "recording",
                        recordings: recordings(target, numbers: numbers),
                        transcriptionModel: method == .cloudTranscription ? settings.summary?.methodSettings.audio?.model : nil
                    )
                    if method == .cloudTranscription, input.transcriptionModel == nil { throw Failure.unavailable }
                }
                guard let selected = method == .audio ? settings.summary?.methodSettings.audio : settings.summary?.methodSettings.transcript else {
                    throw Failure.unavailable
                }
                body = Request(
                    id: id.uuidString.lowercased(),
                    input: input,
                    model: selected.model,
                    detailLevel: detail.map { SummaryDetailLevel.fromPersistedValue($0).rawValue } ?? settings.summary?.detailLevel?
                        .rawValue ?? "high",
                    summaryLanguage: settings.outputLanguage.rawValue
                )
                try await onPrepared(body)
            }
            try Task.checkCancellation()
            job = try await start(target, request: body)
        }
        guard UUID(uuidString: job?.id ?? "") == id else { throw Failure.unavailable }
        while job?.isActive == true {
            await onStage(job?.status == "pending" ? "pending" : job?.stage ?? "summarizing")
            try await Task.sleep(for: .seconds(3))
            guard try await self.target(meetingID: target.meetingID, dbQueue: dbQueue) == target else { throw Failure.unavailable }
            job = try await status(target, id: id)
        }
        if let stage = job?.stage { await onStage(stage) }
        if job?.status == "cancelled" { throw CancellationError() }
        guard job?.status == "succeeded" else { throw Failure.generationFailed(job?.error) }
        await onStage("saving")
        // The normal remote applier owns both generated results.
        try await awaitSynchronization(target, dbQueue: dbQueue)
        if processing?.method != .transcript, processing != nil {
            try await dbQueue.write { db in
                for id in sessionIDs {
                    try db.execute(
                        sql: "UPDATE recording_sessions SET batchCompletedAt = ?, batchLastError = NULL WHERE id = ? AND endedAt IS NOT NULL AND batchDiscardedAt IS NULL",
                        arguments: [Date.now, id]
                    )
                }
            }
        }
    }

    private func awaitRecordingUploads(_ target: Target, sessionIDs: [UUID], dbQueue: DatabaseQueue) async throws {
        guard !sessionIDs.isEmpty else { throw Failure.unavailable }
        while true {
            try Task.checkCancellation()
            guard try await self.target(meetingID: target.meetingID, dbQueue: dbQueue) == target else { throw Failure.unavailable }
            let ready = try await dbQueue.read { db in
                try sessionIDs.allSatisfy { id in
                    guard let session = try RecordingSessionRecord.fetchOne(db, key: id),
                          session.batchDiscardedAt == nil else { throw Failure.unavailable }
                    return try session.endedAt != nil && RecordingArchiveRecord.isAvailable(sessionId: id, in: db)
                }
            }
            if ready { return }
            try await Task.sleep(for: .seconds(3))
        }
    }

    private func recordings(_ target: Target, numbers: [Int]) async throws -> [RecordingPair] {
        struct Page: Decodable {
            struct Item: Decodable {
                struct Audio: Decodable { let fileId: String }
                let id: Int
                let audio: [String: Audio]
            }

            let items: [Item]
            let nextCursor: String?
        }
        var result: [Int: RecordingPair] = [:]
        var cursor: String?
        repeat {
            guard let origin = URL(string: target.origin) else { throw URLError(.badURL) }
            let pageCursor = cursor
            let data = try await client.data(origin: origin, connectionId: target.connectionID, maximumBytes: 2 * 1024 * 1024) {
                try await $0.listRecordings(path: .init(meetingId: target.meetingID.uuidString.lowercased()), query: .init(cursor: pageCursor)).ok
                    .body.json
            }
            let page = try JSONDecoder().decode(Page.self, from: data)
            for item in page.items where numbers.contains(item.id) {
                result[item.id] = RecordingPair(micFileId: item.audio["mic"]?.fileId, systemFileId: item.audio["system"]?.fileId)
            }
            cursor = page.nextCursor
        } while cursor != nil
        return try numbers.map { number in
            guard let pair = result[number] else { throw Failure.unavailable }
            return pair
        }
    }

    private func awaitSynchronization(_ target: Target, dbQueue: DatabaseQueue) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            guard try await self.target(meetingID: target.meetingID, dbQueue: dbQueue) == target else { throw Failure.unavailable }
            let ready = try await dbQueue.read { db in
                try SyncTransactionQueue.matchesExpectedConnection(vaultId: target.vaultID, connectionId: target.connectionID, in: db)
                    && !SyncTransactionQueue.hasPending(vaultId: target.vaultID, in: db)
                    && String.fetchOne(
                        db,
                        sql: "SELECT syncPullCursor FROM vaults WHERE id = ? AND syncRecoveryState IS NULL",
                        arguments: [target.vaultID]
                    ) != nil
            }
            if ready {
                do {
                    try await synchronize(target, dbQueue)
                    return
                } catch TextContentError.changed {
                    // Another pull or local mutation may own the Vault; recheck its connection before retrying.
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw Failure.syncPending
    }

    private func request(origin: String, path: String) throws -> URLRequest {
        guard let origin = URL(string: origin), let url = URL(string: path, relativeTo: origin)?.absoluteURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
