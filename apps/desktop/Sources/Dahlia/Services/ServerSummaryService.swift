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
        let summaryMethods: [String]?
        var supportsAudioSummary: Bool { slug.hasPrefix("gemini-") && inputModalities?.contains("audio") == true }
        func supportsSummary(method: String) -> Bool {
            let source = method == "audio" ? "audio" : "transcript"
            return (summaryMethods?.contains(source) ?? true)
                && (source != "audio" || supportsAudioSummary)
        }

        var id: String { slug }
        private enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case supportedReasoningLevels = "supported_reasoning_levels"
            case defaultReasoningLevel = "default_reasoning_level"
            case inputModalities = "input_modalities"
            case summaryMethods = "summary_methods"
        }
    }

    private struct ModelList: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
        let models: [Model]
    }

    private struct Response: Decodable { let job: Job? }

    private struct TranscriptPage: Decodable {
        let version: Int
        let present: Bool
        let items: [SyncTranscriptPage.Segment]?
        let nextCursor: String?
    }

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
        var model: String?
        var detailLevel: String?
        var summaryLanguage: String?
        var reasoningEffort: String?
        var preferences: ServerAccountSettings.GenerationPreferences?
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
        try await summaryCapability(connectionID: connectionID, origin: origin)?.sources ?? []
    }

    func manualMethods(connectionID: UUID, origin: String) async throws -> [String] {
        guard let summary = try await summaryCapability(connectionID: connectionID, origin: origin) else { return [] }
        return summary.sources.filter { $0 != SummaryGenerationSource.audio.rawValue || summary.completeRecordings }
    }

    private func summaryCapability(connectionID: UUID, origin: String) async throws -> ServerCapabilities.MeetingSummaryGeneration? {
        guard let origin = URL(string: origin) else { throw URLError(.badURL) }
        let data = try await client.data(origin: origin, connectionId: connectionID, maximumBytes: 8192) {
            try await $0.getCapabilities().ok.body.json
        }
        let summary = try JSONDecoder().decode(ServerCapabilities.self, from: data).meetingSummaryGeneration
        return summary?.version == 2 ? summary : nil
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

    func availableTranscriptVersion(_ target: Target, dbQueue: DatabaseQueue) async throws -> Int? {
        let hasPendingMutation = try await dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (
                    SELECT 1 FROM sync_operations o
                    JOIN sync_transactions t ON t.id = o.transactionId
                    WHERE t.vaultId = ? AND o.entity = 'transcript' AND o.entityId = ?
                )
                """,
                arguments: [target.vaultID, target.meetingID]
            ) ?? false
        }
        guard !hasPendingMutation else { return nil }
        return try await latestTranscriptVersion(target)
    }

    func hasAvailableAudio(_ target: Target) async throws -> Bool {
        struct Page: Decodable {
            struct Item: Decodable {}
            let items: [Item]
        }
        guard let origin = URL(string: target.origin) else { throw URLError(.badURL) }
        do {
            let data = try await client.data(
                origin: origin,
                connectionId: target.connectionID,
                maximumBytes: 2 * 1024 * 1024,
                requireCompleteRecordings: true
            ) {
                try await $0.listRecordings(path: .init(meetingId: target.meetingID.uuidString.lowercased())).ok.body.json
            }
            return try !JSONDecoder().decode(Page.self, from: data).items.isEmpty
        } catch let error as SyncHTTPError where error.status == 409 {
            return false
        }
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
        if body.preferences != nil {
            typealias Body = Operations.StartSummaryJob.Input.Body.JsonPayload.Value3Payload
            let value = try JSONDecoder().decode(Body.self, from: JSONEncoder().encode(body))
            return try await start(target, body: .init(value3: value))
        }
        typealias Body = Operations.StartSummaryJob.Input.Body.JsonPayload.Value1Payload
        guard let detailLevel = body.detailLevel, let summaryLanguage = body.summaryLanguage, let selectedModel = body.model,
              let detail = Body.DetailPayload(rawValue: SummaryDetailLevel.fromPersistedValue(detailLevel).rawValue),
              let language = Body.OutputLanguagePayload(rawValue: summaryLanguage) else { throw Failure.unavailable }
        let input = try JSONDecoder().decode(Body.InputPayload.self, from: JSONEncoder().encode(body.input))
        let reasoningEffort = body.reasoningEffort.flatMap(Body.ReasoningEffortPayload.init(rawValue:))
        return try await start(
            target,
            body: .init(value1: Body(
                id: body.id,
                input: input,
                model: selectedModel,
                detail: detail,
                outputLanguage: language,
                reasoningEffort: reasoningEffort
            ))
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
        source: SummaryGenerationSource? = nil,
        preparedRequest: Request? = nil,
        processing: RecordingProcessing? = nil,
        accountSettings: ServerAccountSettings? = nil,
        onPrepared: @Sendable (Request) async throws -> Void = { _ in },
        onStage: @MainActor @Sendable (String) async -> Void = { _ in }
    ) async throws {
        let supportedSources = try await supportedSources(for: source, target: target)
        guard supports(source, in: supportedSources) else { throw Failure.unavailable }
        await onStage("uploading")
        try await awaitSynchronization(target, dbQueue: dbQueue)
        let sessionIDs: [UUID] = if let processing {
            processing.sessionIDs
        } else {
            try await dbQueue.read { db in
                try RecordingSessionRecord.filter(Column("meetingId") == target.meetingID)
                    .order(Column("startedAt").asc).fetchAll(db).map(\.id)
            }
        }
        var job = try await status(target, id: id)
        if job == nil, let previousID = processing?.retryOf {
            job = try await retry(target, previousID: previousID, id: id)
        }
        if job == nil {
            let body: Request
            if var saved = preparedRequest ?? processing?.serverRequest {
                if saved.preferences == nil {
                    saved.reasoningEffort = saved.reasoningEffort ?? processing?.serverSettings?.processing?.remote.reasoningEffort
                }
                body = saved
            } else {
                let settings: ServerAccountSettings
                if let captured = processing?.serverSettings ?? accountSettings {
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
                let isLegacyProcessing = processing != nil && processing?.summaryMode == nil
                guard let summary = settings.summary, let accountProcessing = settings.processing,
                      accountProcessing.location == .remote || settings.legacyMethod != nil || isLegacyProcessing else { throw Failure.unavailable }
                let method = processing?.method ?? source?.processingMethod
                    ?? (accountProcessing.remote.workflow == .combined ? .audio : .cloudTranscription)
                let input: Input
                if method == .transcript {
                    guard let version = try await latestTranscriptVersion(target) else {
                        throw Failure.syncPending
                    }
                    input = Input(type: "transcript", version: String(version))
                } else {
                    try await awaitRecordingUploads(target, sessionIDs: sessionIDs, dbQueue: dbQueue, wait: source == nil)
                    let numbers = try await dbQueue.read { db in
                        try sessionIDs.map { id in
                            guard let number = try RecordingArchiveRecord.fetchOne(db, key: id)?.number else { throw Failure.syncPending }
                            return number
                        }
                    }
                    input = try await Input(
                        type: "recording",
                        recordings: recordings(target, numbers: numbers)
                    )
                }
                var preferences = settings.generationPreferences
                preferences.processing.location = .remote
                preferences.processing.remote.workflow = method == .audio ? .combined : .transcribeThenSummarize
                preferences = await resettingIncompatibleManualModel(preferences, source: source, target: target)
                preferences.summary.style = detail.map { SummaryStyle(detailLevel: .fromPersistedValue($0)) } ?? summary.style
                body = Request(id: id.uuidString.lowercased(), input: input, preferences: preferences)
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

    private func supports(_ source: SummaryGenerationSource?, in supportedSources: [String]) -> Bool {
        source.map { supportedSources.contains($0.rawValue) } ?? !supportedSources.isEmpty
    }

    private func supportedSources(for source: SummaryGenerationSource?, target: Target) async throws -> [String] {
        if source == nil {
            return try await methods(connectionID: target.connectionID, origin: target.origin)
        }
        return try await manualMethods(connectionID: target.connectionID, origin: target.origin)
    }

    private func latestTranscriptVersion(_ target: Target) async throws -> Int? {
        guard let origin = URL(string: target.origin) else { throw URLError(.badURL) }
        var cursor: String?
        var version: Int?
        repeat {
            let pageCursor = cursor
            let data: Data = if let version {
                try await client.data(origin: origin, connectionId: target.connectionID, maximumBytes: 9 * 1024 * 1024) {
                    try await $0.getTranscript(
                        path: .init(meetingId: target.meetingID.uuidString.lowercased(), version: String(version)),
                        query: .init(cursor: pageCursor)
                    ).ok.body.json
                }
            } else {
                try await client.data(origin: origin, connectionId: target.connectionID, maximumBytes: 9 * 1024 * 1024) {
                    try await $0.getLatestTranscript(
                        path: .init(meetingId: target.meetingID.uuidString.lowercased()),
                        query: .init(cursor: pageCursor)
                    ).ok.body.json
                }
            }
            let page = try SyncJSON.decoder.decode(TranscriptPage.self, from: data)
            guard page.present else { return nil }
            version = version ?? page.version
            guard page.version == version else { throw Failure.unavailable }
            if page.items?.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true {
                return version
            }
            cursor = page.nextCursor
        } while cursor != nil
        return nil
    }

    private func resettingIncompatibleManualModel(
        _ preferences: ServerAccountSettings.GenerationPreferences,
        source: SummaryGenerationSource?,
        target: Target
    ) async -> ServerAccountSettings.GenerationPreferences {
        guard let source, let savedModel = preferences.processing.remote.summaryModel else { return preferences }
        guard let models = try? await models(connectionID: target.connectionID, origin: target.origin),
              let model = models.first(where: { $0.id == savedModel || savedModel.hasSuffix("." + $0.id) }),
              !model.supportsSummary(method: source.rawValue) else { return preferences }
        var preferences = preferences
        preferences.processing.remote.summaryModel = nil
        preferences.processing.remote.reasoningEffort = nil
        return preferences
    }

    private func awaitRecordingUploads(
        _ target: Target,
        sessionIDs: [UUID],
        dbQueue: DatabaseQueue,
        wait: Bool
    ) async throws {
        guard !sessionIDs.isEmpty else { throw Failure.unavailable }
        while true {
            try Task.checkCancellation()
            guard try await self.target(meetingID: target.meetingID, dbQueue: dbQueue) == target else { throw Failure.unavailable }
            let ready = try await dbQueue.read { db in
                try sessionIDs.allSatisfy { id in
                    guard let session = try RecordingSessionRecord.fetchOne(db, key: id),
                          session.transcriptionMode == .batch,
                          session.batchDiscardedAt == nil else { throw Failure.unavailable }
                    return try session.endedAt != nil && RecordingArchiveRecord.isAvailable(sessionId: id, in: db)
                }
            }
            if ready { return }
            guard wait else { throw Failure.syncPending }
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
