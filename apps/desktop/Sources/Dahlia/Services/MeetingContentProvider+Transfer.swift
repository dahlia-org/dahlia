import DahliaRuntimeSupport
import Foundation
import GRDB

extension MeetingContentProvider {
    func prepareAccountTransfer(vaultIds: [UUID], connectionId: UUID, dbQueue: DatabaseQueue) async throws -> [UUID: SearchSource] {
        for vaultId in vaultIds {
            retainVault(vaultId, dbQueue: dbQueue)
        }
        do {
            var sources: [UUID: SearchSource] = [:]
            let worker = SyncWorker(dbQueue: dbQueue, session: client.session, apiClient: client)
            for vaultId in vaultIds {
                try await worker.synchronizeForTransfer(vaultId: vaultId, connectionId: connectionId)
                guard let source = try await dbQueue.read({ try SearchSource.read(vaultId: vaultId, in: $0) }),
                      source.connectionId == connectionId else { throw TextContentError.changed }
                sources[vaultId] = source
                for (table, entities) in [("meetings", [TextContentEntity.summary, .transcript]), ("files", [.file])] {
                    var cursor: UUID?
                    while true {
                        let after = cursor
                        let ids = try await dbQueue.read { db in
                            try UUID.fetchAll(
                                db,
                                sql: "SELECT id FROM \(table) WHERE vaultId = ? \(after == nil ? "" : "AND id > ?") ORDER BY id LIMIT 100",
                                arguments: StatementArguments([vaultId] + (after.map { [$0] } ?? []))
                            )
                        }
                        guard !ids.isEmpty else { break }
                        for id in ids {
                            for entity in entities {
                                try await ensure(entity: entity, id: id, dbQueue: dbQueue, refresh: true)
                            }
                        }
                        cursor = ids.last
                    }
                }
                try await dbQueue.read { db in
                    guard try SearchSource.read(vaultId: vaultId, in: db) == source else { throw TextContentError.changed }
                    try TextContentStore.requireVaultComplete(vaultId: vaultId, in: db)
                }
            }
            return sources
        } catch {
            releaseAccountTransfer(vaultIds: vaultIds, dbQueue: dbQueue)
            throw error
        }
    }

    func releaseAccountTransfer(vaultIds: [UUID], dbQueue: DatabaseQueue) {
        for vaultId in vaultIds {
            releaseVault(vaultId, dbQueue: dbQueue)
        }
    }
}
