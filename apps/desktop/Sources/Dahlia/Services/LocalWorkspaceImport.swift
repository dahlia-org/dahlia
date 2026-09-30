import Foundation
import GRDB

enum LocalWorkspaceImportError: LocalizedError {
    case unavailable, changed, collision

    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.workspaceImportUnavailable
        case .changed: L10n.workspaceImportChanged
        case .collision: L10n.workspaceImportCollision
        }
    }
}

enum LocalWorkspaceImport {
    static func createDestination(
        sourceId: UUID,
        organizationId: UUID,
        name: String,
        connection: DahliaAccountConnectionRecord,
        dbQueue: DatabaseQueue,
        api: SyncAPIClient
    ) async throws -> CloudWorkspaceRecord {
        let prepared = try await dbQueue.write { db in
            try WorkspaceImportDestinationRecord.prepare(
                sourceId: sourceId,
                connection: connection,
                organizationId: organizationId,
                name: name,
                in: db
            )
        }
        var remote = try await CloudWorkspaceDiscovery.fetch(connection: connection, apiClient: api)
            .first(where: { $0.workspaceId == prepared.destinationWorkspaceId })
        if remote == nil {
            try await CloudWorkspaceDiscovery.createWorkspace(request: prepared.requestJSON, connection: connection, api: api)
            remote = try await CloudWorkspaceDiscovery.fetch(connection: connection, apiClient: api)
                .first(where: { $0.workspaceId == prepared.destinationWorkspaceId })
        }
        guard let remote, remote.organizationId == organizationId, ["admin", "editor"].contains(remote.role) else {
            throw LocalWorkspaceImportError.unavailable
        }
        _ = try await MeetingRepository.registerDiscoveredCloudWorkspaces([remote], connection: connection, dbQueue: dbQueue)
        return remote
    }

    static func run(
        sourceId: UUID,
        destination: CloudWorkspaceRecord,
        dbQueue: DatabaseQueue,
        backup: BackupService,
        api: SyncAPIClient = SyncAPIClient(session: .shared),
        replaceServerImageAnalysis: Bool = false,
        reconnectExisting: Bool = false,
        screenshots: ScreenshotContentProvider = .shared
    ) async throws -> WorkspaceRecord {
        guard sourceId != destination.workspaceId || reconnectExisting else { throw LocalWorkspaceImportError.collision }
        let connection = try await dbQueue.read { db in
            try validate(sourceId: sourceId, destination: destination, reconnectExisting: reconnectExisting, in: db)
            return try DahliaAccountConnectionRecord.fetchOne(db, key: destination.connectionId)
        }
        guard let connection, let origin = URL(string: connection.origin) else { throw LocalWorkspaceImportError.unavailable }
        try await DocumentPersistence(dbQueue: dbQueue).prepareAccountTransfer(workspaceID: sourceId)
        let worker = SyncWorker(dbQueue: dbQueue, apiClient: api)
        if !reconnectExisting {
            try await worker.synchronizeForTransfer(workspaceId: destination.workspaceId, connectionId: destination.connectionId)
        }
        screenshots.retainOriginals(workspaceIds: [sourceId], dbQueue: dbQueue)
        defer { screenshots.releaseOriginals(workspaceIds: [sourceId], dbQueue: dbQueue) }
        let files = try await screenshots.prepareAccountTransfer(workspaceId: sourceId, connectionId: connection.id, dbQueue: dbQueue)
        let fence = try await dbQueue.write { db in
            try validate(sourceId: sourceId, destination: destination, reconnectExisting: reconnectExisting, in: db)
            return try WorkspaceTransferFence.create(
                workspaceIDs: [sourceId, destination.workspaceId],
                blockingRemoteChangesIn: [destination.workspaceId],
                in: db
            )
        }
        do {
            let generation = try await backup.createGeneration(workspaceIds: [sourceId])
            let reconnection = reconnectExisting
                ? try await worker.reconnectionSnapshot(workspaceId: destination.workspaceId, connectionId: connection.id, origin: origin) : nil
            let snapshot: SyncResetSnapshot = if let reconnection {
                reconnection.ids
            } else {
                try await worker.importSnapshot(workspaceId: destination.workspaceId, connectionId: connection.id, origin: origin)
            }
            guard let current = try await CloudWorkspaceDiscovery.fetch(connection: connection, apiClient: api)
                .first(where: { $0.workspaceId == destination.workspaceId }),
                ["admin", "editor"].contains(current.role), current.organizationId == destination.organizationId else {
                throw LocalWorkspaceImportError.unavailable
            }
            return try await dbQueue.write { db in
                guard try fence.isCurrent(in: db),
                      let currentConnection = try DahliaAccountConnectionRecord.fetchOne(db, key: connection.id),
                      currentConnection.origin == connection.origin, currentConnection.clientID == connection.clientID else {
                    throw LocalWorkspaceImportError.changed
                }
                let result = try commit(
                    sourceId: sourceId,
                    destination: current,
                    snapshot: snapshot,
                    files: files,
                    backupPath: generation.fileURL.path,
                    replaceServerImageAnalysis: replaceServerImageAnalysis,
                    reconnection: reconnection,
                    in: db
                )
                try fence.release(in: db)
                return result
            }
        } catch {
            try? await dbQueue.write { try fence.release(in: $0) }
            throw error
        }
    }

    static func validate(
        sourceId: UUID,
        destination: CloudWorkspaceRecord,
        reconnectExisting: Bool = false,
        in db: Database
    ) throws {
        guard let source = try WorkspaceRecord.fetchOne(db, key: sourceId), source.accountConnectionId == nil,
              let target = try WorkspaceRecord.fetchOne(db, key: destination.workspaceId),
              ["admin", "editor"].contains(destination.role),
              (reconnectExisting && sourceId == destination.workspaceId) || (
                  target.accountConnectionId == destination.connectionId && target.organizationId == destination.organizationId
                      && target.allowsCanonicalEdits && target.syncConfirmedConnectionId == destination.connectionId
                      && (target.syncRecoveryState == nil || reconnectExisting && target.syncRecoveryState == "pending")
              ),
              try !SyncTransactionQueue.hasPending(workspaceId: sourceId, in: db),
              try !SyncTransactionQueue.hasPending(workspaceId: target.id, in: db),
              try !RecordingSessionRecord.hasActiveRecording(workspaceId: sourceId, in: db),
              try !RecordingSessionRecord.hasActiveRecording(workspaceId: target.id, in: db) else {
            throw LocalWorkspaceImportError.unavailable
        }
        let pendingAudio = try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM recording_archives WHERE workspace_id = ?
          AND state NOT IN ('saved', 'remote', 'expired'))
        """, arguments: [target.id]) == true
        guard sourceId == target.id || !pendingAudio else { throw LocalWorkspaceImportError.unavailable }
    }

    static func commit(
        sourceId: UUID,
        destination: CloudWorkspaceRecord,
        snapshot: SyncResetSnapshot,
        files: [FileTransfer],
        backupPath: String,
        replaceServerImageAnalysis: Bool = false,
        reconnection: WorkspaceReconnectionSnapshot? = nil,
        in db: Database
    ) throws -> WorkspaceRecord {
        try validate(sourceId: sourceId, destination: destination, reconnectExisting: reconnection != nil, in: db)
        try DocumentPersistence.preservePrivateCopies(workspaceID: sourceId, in: db)
        guard var target = try WorkspaceRecord.fetchOne(db, key: destination.workspaceId),
              reconnection != nil || target.syncPullCursor != nil else {
            throw LocalWorkspaceImportError.unavailable
        }
        if sourceId == target.id {
            target.accountConnectionId = destination.connectionId
            target.organizationId = destination.organizationId
            target.personalUserId = destination.personalUserId
            target.syncRole = destination.role
            target.syncConfirmedConnectionId = destination.connectionId
            try target.update(db)
        }
        try reconnection?.adoptAbsence(workspaceId: sourceId, in: db)
        var moves: [(WorkspaceRelocation.Item, UUID)] = []
        for (entity, table, remote) in [
            (SyncEntity.project, "projects", snapshot.projects),
            (.meeting, "meetings", snapshot.meetings),
            (.file, "files", snapshot.files),
        ] {
            let ids = try UUID.fetchAll(db, sql: "SELECT id FROM \(table) WHERE workspace_id = ?", arguments: [sourceId])
            guard reconnection != nil || remote.isDisjoint(with: ids) else { throw LocalWorkspaceImportError.collision }
            moves += ids.map { (.init(entity: entity, id: $0, workspaceId: target.id), sourceId) }
        }
        for (table, column, remote) in [
            ("meeting_attachments", "id", snapshot.screenshots),
            ("recording_sessions", "id", snapshot.recordings),
        ] {
            let ids = try UUID.fetchAll(
                db,
                sql: "SELECT \(column) FROM \(table) WHERE meetingId IN (SELECT id FROM meetings WHERE workspace_id = ?)",
                arguments: [sourceId]
            )
            guard reconnection != nil || remote.isDisjoint(with: ids) else { throw LocalWorkspaceImportError.collision }
        }
        let record = LocalWorkspaceImportRecord(
            id: .v7(),
            sourceWorkspaceId: sourceId,
            destinationWorkspaceId: target.id,
            connectionId: destination.connectionId,
            backupPath: backupPath,
            createdAt: .now
        )
        try record.insert(db)
        if reconnection == nil { try ScreenshotContentProvider.installTransfers(files, workspaceId: sourceId, in: db) }
        if sourceId != target.id { try WorkspaceRelocation.move(moves, in: db) }
        try db.execute(sql: "UPDATE document_private_copies SET workspace_id = ? WHERE workspace_id = ?", arguments: [target.id, sourceId])
        try db.execute(sql: "UPDATE document_local_archives SET workspace_id = ? WHERE workspace_id = ?", arguments: [target.id, sourceId])
        // A Local revision is not a Server base revision. Reconnection reinstalls confirmed Server revisions below.
        for (item, _) in moves {
            try db.execute(sql: "DELETE FROM sync_relation_history WHERE entity = ? AND entityId = ?", arguments: [item.entity, item.id])
            try db.execute(sql: "DELETE FROM sync_confirmed_relations WHERE entity = ? AND entityId = ?", arguments: [item.entity, item.id])
            try db.execute(sql: "DELETE FROM sync_entity_state WHERE workspace_id = ? AND entityId = ?", arguments: [target.id, item.id])
            try db.execute(
                sql: "UPDATE sync_content_state SET residentRevision = NULL WHERE workspace_id = ? AND entityId = ?",
                arguments: [target.id, item.id]
            )
        }
        try reconnection?.apply(workspaceId: target.id, advanceCursor: sourceId == target.id, in: db)
        if reconnection == nil {
            try SyncInitialProgress.start(
                workspaceId: target.id,
                connectionId: destination.connectionId,
                restoring: false,
                replaceImages: replaceServerImageAnalysis,
                importId: record.id,
                items: moves.map(\.0),
                existing: .init(ids: [:]),
                in: db
            )
            try SyncInitialSnapshotBuilder.enqueueRecordingContents(
                moves.map(\.0),
                workspaceId: target.id,
                existing: .init(ids: [:]),
                in: db
            )
        }
        try WorkspaceImportDestinationRecord.filter(Column("sourceWorkspaceId") == sourceId
            && Column("connectionId") == destination.connectionId
            && Column("destinationWorkspaceId") == target.id).deleteAll(db)
        try LocalWorkspaceImportRecord.complete(in: db)
        return try WorkspaceRecord.fetchOne(db, key: target.id) ?? target
    }

}
