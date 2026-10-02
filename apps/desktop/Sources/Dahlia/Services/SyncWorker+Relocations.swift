import Foundation
import GRDB

extension SyncWorker {
    func reconcileRelocations(
        workspaceId: UUID,
        connectionId: UUID,
        origin: URL,
        clearPullIncidentOnSuccess: Bool = false,
        useCachedResult: Bool = false
    ) async throws -> Bool {
        guard transferConnections.contains(connectionId) else { return false }
        let generation = try await dbQueue.read { db -> Int in
            guard let generation = try Int.fetchOne(
                db,
                sql: "SELECT syncLifecycleGeneration FROM workspaces WHERE id = ? AND accountConnectionId = ?",
                arguments: [workspaceId, connectionId]
            )
            else { throw CancellationError() }
            return generation
        }
        try Task.checkCancellation()
        let key = RelocationKey(connectionId: connectionId, workspaceId: workspaceId, origin: origin, generation: generation)
        // Cache only unchanged push preflights. Pull still checks before applying each page.
        relocationResults = relocationResults.filter { Date.now.timeIntervalSince($0.value) < 5 }
        if useCachedResult, relocationResults[key] != nil { return false }
        do {
            let request: (id: UUID, task: Task<WorkspaceRelocation, Error>)
            if let existing = relocationRequests[key] {
                request = existing
            } else {
                let api = apiClient
                request = (UUID(), Task {
                    let data = try await api.data(origin: origin, connectionId: connectionId) {
                        try await $0.getRelocations(path: .init(workspaceId: workspaceId.uuidString.lowercased())).ok.body.json
                    }
                    return try SyncJSON.decoder.decode(WorkspaceRelocation.self, from: data)
                })
                relocationRequests[key] = request
            }
            defer {
                if relocationRequests[key]?.id == request.id { relocationRequests[key] = nil }
            }
            let relocation = try await request.task.value
            try Task.checkCancellation()
            let changed = try await dbQueue.write { db in
                guard try Int.fetchOne(
                    db,
                    sql: "SELECT syncLifecycleGeneration FROM workspaces WHERE id = ? AND accountConnectionId = ?",
                    arguments: [workspaceId, connectionId]
                ) == generation
                else { throw CancellationError() }
                let changed = try relocation.apply(connectionId: connectionId, in: db)
                try db.execute(
                    sql: "UPDATE workspaces SET syncRecoveryState = NULL WHERE id = ? AND accountConnectionId = ? AND syncRecoveryState = 'transferBlocked'",
                    arguments: [workspaceId, connectionId]
                )
                if changed, clearPullIncidentOnSuccess {
                    try db.execute(
                        sql: "UPDATE workspaces SET syncPullErrorJSON = NULL WHERE id = ? AND accountConnectionId = ? AND syncConfirmedConnectionId = ?",
                        arguments: [workspaceId, connectionId, connectionId]
                    )
                }
                return changed
            }
            if changed {
                relocationResults.removeAll()
                await workspacesDidChange()
            } else {
                relocationResults[key] = .now
            }
            return changed
        } catch let error as SyncHTTPError {
            relocationResults[key] = nil
            if error.code == "transfer_access_required" || error.code == "transfer_local_changes" {
                try await dbQueue.write { db in
                    guard try SyncTransactionQueue.matchesExpectedConnection(workspaceId: workspaceId, connectionId: connectionId, in: db)
                    else { return }
                    try db.execute(sql: "UPDATE workspaces SET syncRecoveryState = 'transferBlocked' WHERE id = ?", arguments: [workspaceId])
                }
            }
            throw error
        }
    }

}
