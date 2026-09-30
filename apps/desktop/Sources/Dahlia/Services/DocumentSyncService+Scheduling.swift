import Foundation
import GRDB
import OpenAPIRuntime
import Synchronization

/// Weak entries avoid extending a database's lifetime; a live service retains its database identity.
private enum DocumentSyncServices {
    struct Entry: Sendable { weak var service: DocumentSyncService? }
    static let entries = Mutex<[ObjectIdentifier: Entry]>([:])
}

extension DocumentSyncService {
    nonisolated static func shared(dbQueue: DatabaseQueue, api: SyncAPIClient = SyncAPIClient(session: .shared)) -> DocumentSyncService {
        DocumentSyncServices.entries.withLock { entries in
            entries = entries.filter { $0.value.service != nil }
            let key = ObjectIdentifier(dbQueue)
            if let service = entries[key]?.service { return service }
            let service = DocumentSyncService(dbQueue: dbQueue, api: api)
            entries[key] = .init(service: service)
            return service
        }
    }

    /// Fixed window from the first durable edit, never a quiet-period debounce.
    func localCommitted(meetingID: UUID) {
        requestedSends.insert(meetingID)
        guard sendTasks[meetingID] == nil else { return }
        let wait = waitForSendWindow
        let window = SyncDiagnostics.begin("DocumentSendWindow")
        sendTasks[meetingID] = Task { [weak self] in
            do { try await wait() } catch {
                SyncDiagnostics.end("DocumentSendWindow", window)
                return
            }
            SyncDiagnostics.end("DocumentSendWindow", window)
            await self?.sendCommitted(meetingID: meetingID)
        }
    }

    private func sendCommitted(meetingID: UUID) async {
        defer { sendTasks[meetingID] = nil }
        while requestedSends.remove(meetingID) != nil, !Task.isCancelled {
            do {
                try await synchronize(meetingID: meetingID)
            } catch { notify(meetingID: meetingID, succeeded: false)
                return
            }
        }
    }

    func observe(meetingID: UUID) -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[meetingID, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(meetingID: meetingID, id: id) } }
        if observationTasks[meetingID] == nil {
            observationTasks[meetingID] = Task { [weak self] in await self?.observeRemote(meetingID: meetingID) }
        }
        return stream
    }

    private func removeObserver(meetingID: UUID, id: UUID) {
        observers[meetingID]?[id] = nil
        guard observers[meetingID]?.isEmpty == true else { return }
        observers[meetingID] = nil
        observationTasks.removeValue(forKey: meetingID)?.cancel()
        connectedDocuments.remove(meetingID)
    }

    func notify(meetingID: UUID, succeeded: Bool) {
        for continuation in observers[meetingID]?.values ?? [:].values {
            continuation.yield(succeeded)
        }
    }

    private func observeRemote(meetingID: UUID) async {
        while !Task.isCancelled {
            do {
                try await synchronize(meetingID: meetingID)
                guard let target = try await target(meetingID: meetingID),
                      let document = try await dbQueue.read({ try target.document(in: $0) }), document.generation != nil else {
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.consumeEvents(target: target, documentID: document.id, meetingID: meetingID) }
                    group.addTask { [dbQueue] in
                        let validity = ValueObservation.tracking { db in (try? target.validate(in: db)) != nil }.removeDuplicates()
                        for try await valid in validity.values(in: dbQueue) where !valid {
                            throw DocumentCoreError.unavailable
                        }
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            } catch is CancellationError {
                if Task.isCancelled { return }
            } catch {
                if !Task.isCancelled { notify(meetingID: meetingID, succeeded: false) }
            }
            connectedDocuments.remove(meetingID)
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func consumeEvents(target: Target, documentID: UUID, meetingID: UUID) async throws {
        let body = try await api.perform(origin: target.origin, connectionId: target.connectionID) {
            try await $0.getDocumentEvents(path: .init(
                workspaceId: target.workspaceID.uuidString.lowercased(), documentId: documentID.uuidString.lowercased()
            )).ok.body.textEventStream
        }
        connectedDocuments.insert(meetingID)
        // Subscribe before rereading: changes in the handshake gap cannot be lost.
        try await synchronize(meetingID: meetingID)
        for try await event in body.asDecodedServerSentEvents() {
            try Task.checkCancellation()
            try await dbQueue.read { try target.validate(in: $0) }
            if event.event == "invalidation" { try await synchronize(meetingID: meetingID) }
        }
    }

}
