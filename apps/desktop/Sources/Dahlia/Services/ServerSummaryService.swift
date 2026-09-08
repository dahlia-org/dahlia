import DahliaRuntimeSupport
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
        var isActive: Bool { status == "pending" || status == "processing" }
    }

    struct Model: Decodable, Identifiable, Sendable {
        struct Effort: Decodable, Sendable { let effort: String }
        let slug: String
        let displayName: String
        let supportedReasoningLevels: [Effort]
        let defaultReasoningLevel: String?
        let inputModalities: [String]?
        var supportsAudioSummary: Bool { slug.hasPrefix("gemini-") && inputModalities?.contains("audio") == true }
        var id: String { slug }
        private enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case supportedReasoningLevels = "supported_reasoning_levels"
            case defaultReasoningLevel = "default_reasoning_level"
            case inputModalities = "input_modalities"
        }
    }

    private struct ModelList: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
        let models: [Model]
    }

    private struct Response: Decodable { let job: Job? }
    private struct Capabilities: Decodable {
        struct SummaryGeneration: Decodable {
            let version: Int
            let methods: [String]
        }

        let summaryGeneration: SummaryGeneration?
    }

    private struct Start: Encodable { let id: String
        let detail: String?
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
        let request = try request(origin: origin, path: "/api/v1/capabilities")
        let data = try await client.data(for: request, connectionId: connectionID, maximumBytes: 8192)
        let summary = try JSONDecoder().decode(Capabilities.self, from: data).summaryGeneration
        return summary?.version == 1 ? summary?.methods ?? [] : []
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

    func status(_ target: Target) async throws -> Job? {
        let data = try await client.data(for: request(target, path: "summary/job"), connectionId: target.connectionID, maximumBytes: 8192)
        return try JSONDecoder().decode(Response.self, from: data).job
    }

    func start(_ target: Target, id: UUID, detail: String?) async throws -> Job? {
        var request = try request(target, path: "summary")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Start(id: id.uuidString.lowercased(), detail: detail))
        let data = try await client.data(for: request, connectionId: target.connectionID, maximumBytes: 8192)
        return try JSONDecoder().decode(Response.self, from: data).job
    }

    func generate(_ target: Target, id: UUID, detail: String?, dbQueue: DatabaseQueue) async throws {
        guard try await !methods(connectionID: target.connectionID, origin: target.origin).isEmpty else { throw Failure.unavailable }
        try await awaitSynchronization(target, dbQueue: dbQueue)
        var job = try await status(target)
        if job?.isActive != true {
            do {
                job = try await start(target, id: id, detail: detail)
            } catch let error as SyncHTTPError where error.status == 409 && error.code == "summary_already_running" {
                job = try await status(target)
            }
        }
        guard let jobID = job?.id else { throw Failure.unavailable }
        while job?.isActive == true {
            try await Task.sleep(for: .seconds(3))
            guard try await self.target(meetingID: target.meetingID, dbQueue: dbQueue) == target else { throw Failure.unavailable }
            job = try await status(target)
            guard job?.id == jobID else { throw Failure.unavailable }
        }
        guard job?.status == "succeeded" else { throw Failure.generationFailed(job?.error) }
        // The normal remote applier owns the result. Never applyGeneratedSummary or enqueue a local summary mutation.
        try await awaitSynchronization(target, dbQueue: dbQueue)
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

    private func request(_ target: Target, path: String) throws -> URLRequest {
        try request(
            origin: target.origin,
            path: "/api/v1/vaults/\(target.vaultID.uuidString.lowercased())/meetings/\(target.meetingID.uuidString.lowercased())/\(path)"
        )
    }

    private func request(origin: String, path: String) throws -> URLRequest {
        guard let origin = URL(string: origin), let url = URL(string: path, relativeTo: origin)?.absoluteURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
