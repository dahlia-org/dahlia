import DahliaRuntimeSupport
import DahliaServerAPI
import Foundation
import GRDB

/// One coalescing sender per recording; failures never enter the durable recording lane.
actor LiveTranscriptPublisher {
    static let shared = LiveTranscriptPublisher()
    private let liveStore: LiveTranscriptStore
    private let publish: @Sendable (LiveTranscriptState, DatabaseQueue) async throws -> Bool

    init(
        store: LiveTranscriptStore = .shared,
        publish: (@Sendable (LiveTranscriptState, DatabaseQueue) async throws -> Bool)? = nil
    ) {
        liveStore = store
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let client = SyncAPIClient(session: URLSession(configuration: configuration))
        self.publish = publish ?? { state, database in
            guard let source = try await database.read({ db in
                try MeetingContentProvider.SearchSource.read(vaultId: state.vaultId, in: db)
            }), let origin = URL(string: source.origin) else { return false }
            let bytes = try SyncJSON.encoder.encode(state)
            let payload = try SyncJSON.decoder.decode(Components.Schemas.LiveTranscriptUpdate.self, from: bytes)
            _ = try await client.data(origin: origin, connectionId: source.connectionId, maximumBytes: 8192) {
                try await $0.putLiveTranscript(path: .init(meetingId: state.meetingId.uuidString.lowercased()), body: .json(payload)).noContent
            }
            return true
        }
    }

    private var workers: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]

    @discardableResult
    func start(meetingID: UUID, database: DatabaseQueue) -> Task<Void, Never> {
        workers[meetingID]?.task.cancel()
        let workerID = UUID.v7()
        let sessionID = liveStore.snapshot(meetingID: meetingID, database: database)?.sessionId
        let task = Task {
            defer { if workers[meetingID]?.id == workerID { workers[meetingID] = nil } }
            var sentRevision: Int?
            var sentAt = Date.distantPast
            var sequence = 0
            var terminalAttempts = 0
            while !Task.isCancelled {
                guard var state = liveStore.snapshot(meetingID: meetingID, database: database),
                      state.sessionId == sessionID else { return }
                let terminal = state.status == .stopped || state.status == .failed
                if state.sequence != sentRevision || Date().timeIntervalSince(sentAt) >= 15 || terminal {
                    let revision = state.sequence
                    sequence += 1
                    state.sequence = sequence
                    state.updatedAt = .now
                    do {
                        guard try await publish(state, database) else {
                            if terminal { return }
                            try await Task.sleep(for: .seconds(1))
                            continue
                        }
                        sentRevision = revision
                        sentAt = .now
                        if terminal { return }
                    } catch is CancellationError { return } catch {
                        if terminal { terminalAttempts += 1
                            if terminalAttempts >= 3 { return }
                        }
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        workers[meetingID] = (workerID, task)
        return task
    }
}
