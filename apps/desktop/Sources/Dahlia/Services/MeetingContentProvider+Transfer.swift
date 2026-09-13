import DahliaRuntimeSupport
import Foundation
import GRDB

extension MeetingContentProvider {
    struct TransferSource: Equatable, Sendable {
        let source: SearchSource
        let cursor: String

        static func read(workspaceId: UUID, in db: Database) throws -> Self? {
            guard let source = try SearchSource.read(workspaceId: workspaceId, in: db),
                  let cursor = try String.fetchOne(db, sql: "SELECT syncPullCursor FROM workspaces WHERE id = ?", arguments: [workspaceId])
            else { return nil }
            return Self(source: source, cursor: cursor)
        }
    }

    func prepareAccountTransfer(workspaceIds: [UUID], connectionId: UUID, dbQueue: DatabaseQueue) async throws -> [UUID: TransferSource] {
        for workspaceId in workspaceIds {
            retainWorkspace(workspaceId, dbQueue: dbQueue)
        }
        do {
            var sources: [UUID: TransferSource] = [:]
            let worker = SyncWorker(dbQueue: dbQueue, session: client.session, apiClient: client)
            for workspaceId in workspaceIds {
                try await worker.synchronizeForTransfer(workspaceId: workspaceId, connectionId: connectionId)
                guard let source = try await dbQueue.read({ try TransferSource.read(workspaceId: workspaceId, in: $0) }),
                      source.source.connectionId == connectionId else { throw TextContentError.changed }
                sources[workspaceId] = source
                for (table, entities) in [("meetings", [TextContentEntity.summary, .transcript]), ("files", [.file])] {
                    var cursor: UUID?
                    while true {
                        let after = cursor
                        let ids = try await dbQueue.read { db in
                            try UUID.fetchAll(
                                db,
                                sql: "SELECT id FROM \(table) WHERE workspace_id = ? \(after == nil ? "" : "AND id > ?") ORDER BY id LIMIT 100",
                                arguments: StatementArguments([workspaceId] + (after.map { [$0] } ?? []))
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
                    guard try TransferSource.read(workspaceId: workspaceId, in: db) == source else { throw TextContentError.changed }
                    try TextContentStore.requireWorkspaceComplete(workspaceId: workspaceId, in: db)
                }
            }
            return sources
        } catch {
            releaseAccountTransfer(workspaceIds: workspaceIds, dbQueue: dbQueue)
            throw error
        }
    }

    func validateAccountTransfer(_ sources: [UUID: TransferSource], dbQueue: DatabaseQueue) async throws {
        let worker = SyncWorker(dbQueue: dbQueue, session: client.session, apiClient: client)
        for (workspaceId, source) in sources {
            try await worker.validateTransferCursor(workspaceId: workspaceId, connectionId: source.source.connectionId, cursor: source.cursor)
        }
        try Task.checkCancellation()
    }

    func releaseAccountTransfer(workspaceIds: [UUID], dbQueue: DatabaseQueue) {
        for workspaceId in workspaceIds {
            releaseWorkspace(workspaceId, dbQueue: dbQueue)
        }
    }
}
