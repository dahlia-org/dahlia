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
    static func run(
        sourceId: UUID,
        destination: CloudWorkspaceRecord,
        dbQueue: DatabaseQueue,
        backup: BackupService,
        api: SyncAPIClient = SyncAPIClient(session: .shared),
        screenshots: ScreenshotContentProvider = .shared
    ) async throws -> WorkspaceRecord {
        guard sourceId != destination.workspaceId else { throw LocalWorkspaceImportError.collision }
        let connection = try await dbQueue.read { db in
            try validate(sourceId: sourceId, destination: destination, in: db)
            return try DahliaAccountConnectionRecord.fetchOne(db, key: destination.connectionId)
        }
        guard let connection, let origin = URL(string: connection.origin) else { throw LocalWorkspaceImportError.unavailable }
        let worker = SyncWorker(dbQueue: dbQueue, apiClient: api)
        try await worker.synchronizeForTransfer(workspaceId: destination.workspaceId, connectionId: destination.connectionId)
        screenshots.retainOriginals(workspaceIds: [sourceId], dbQueue: dbQueue)
        defer { screenshots.releaseOriginals(workspaceIds: [sourceId], dbQueue: dbQueue) }
        let files = try await screenshots.prepareAccountTransfer(workspaceId: sourceId, connectionId: connection.id, dbQueue: dbQueue)
        // ponytail: a database-wide fence may reject unrelated background writes; use per-Workspace generations if contention matters.
        let fence = try await dbQueue.read { db in
            try validate(sourceId: sourceId, destination: destination, in: db)
            return db.totalChangesCount
        }
        let generation = try await backup.createGeneration(workspaceIds: [sourceId])
        let snapshot = try await worker.importSnapshot(workspaceId: destination.workspaceId, connectionId: connection.id, origin: origin)
        guard let current = try await CloudWorkspaceDiscovery.fetch(connection: connection, apiClient: api)
            .first(where: { $0.workspaceId == destination.workspaceId }),
            ["admin", "editor"].contains(current.role), current.organizationId == destination.organizationId else {
            throw LocalWorkspaceImportError.unavailable
        }
        return try await dbQueue.write { db in
            guard db.totalChangesCount == fence,
                  try DahliaAccountConnectionRecord.fetchOne(db, key: connection.id) == connection else {
                throw LocalWorkspaceImportError.changed
            }
            return try commit(
                sourceId: sourceId,
                destination: current,
                snapshot: snapshot,
                files: files,
                backupPath: generation.fileURL.path,
                in: db
            )
        }
    }

    static func validate(
        sourceId: UUID,
        destination: CloudWorkspaceRecord,
        in db: Database
    ) throws {
        guard let source = try WorkspaceRecord.fetchOne(db, key: sourceId), source.accountConnectionId == nil,
              let target = try WorkspaceRecord.fetchOne(db, key: destination.workspaceId),
              target.accountConnectionId == destination.connectionId, target.organizationId == destination.organizationId,
              target.allowsCanonicalEdits, ["admin", "editor"].contains(destination.role),
              target.syncConfirmedConnectionId == destination.connectionId, target.syncRecoveryState == nil,
              try !SyncTransactionQueue.hasPending(workspaceId: sourceId, in: db),
              try !SyncTransactionQueue.hasPending(workspaceId: target.id, in: db),
              try !RecordingSessionRecord.hasActiveRecording(workspaceId: sourceId, in: db),
              try !RecordingSessionRecord.hasActiveRecording(workspaceId: target.id, in: db) else {
            throw LocalWorkspaceImportError.unavailable
        }
        let pendingAudio = try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM recording_archives WHERE workspace_id IN (?, ?)
          AND state NOT IN ('saved', 'remote'))
        """, arguments: [sourceId, target.id]) == true
        guard !pendingAudio else { throw LocalWorkspaceImportError.unavailable }
    }

    static func commit(
        sourceId: UUID,
        destination: CloudWorkspaceRecord,
        snapshot: SyncResetSnapshot,
        files: [FileTransfer],
        backupPath: String,
        in db: Database
    ) throws -> WorkspaceRecord {
        try validate(sourceId: sourceId, destination: destination, in: db)
        guard let target = try WorkspaceRecord.fetchOne(db, key: destination.workspaceId), target.syncPullCursor != nil else {
            throw LocalWorkspaceImportError.unavailable
        }
        var moves: [(WorkspaceRelocation.Item, UUID)] = []
        for (entity, table, remote) in [
            (SyncEntity.project, "projects", snapshot.projects),
            (.meeting, "meetings", snapshot.meetings),
            (.file, "files", snapshot.files),
        ] {
            let ids = try UUID.fetchAll(db, sql: "SELECT id FROM \(table) WHERE workspace_id = ?", arguments: [sourceId])
            guard remote.isDisjoint(with: ids) else { throw LocalWorkspaceImportError.collision }
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
            guard remote.isDisjoint(with: ids) else { throw LocalWorkspaceImportError.collision }
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
        try ScreenshotContentProvider.installTransfers(files, workspaceId: sourceId, in: db)
        try WorkspaceRelocation.move(moves, in: db)
        // A Local revision is not a Server base revision. Only the imported entities are new.
        for (item, _) in moves {
            try db.execute(sql: "DELETE FROM sync_entity_state WHERE workspace_id = ? AND entityId = ?", arguments: [target.id, item.id])
            try db.execute(
                sql: "UPDATE sync_content_state SET residentRevision = NULL WHERE workspace_id = ? AND entityId = ?",
                arguments: [target.id, item.id]
            )
        }
        try SyncInitialSnapshotBuilder.enqueueContents(moves.map(\.0), workspaceId: target.id, in: db)
        try db.execute(sql: """
        INSERT INTO local_workspace_import_operations(operationId, importId)
        SELECT o.id, ? FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId WHERE t.workspace_id = ?
        """, arguments: [record.id, target.id])
        try LocalWorkspaceImportRecord.complete(in: db)
        return target
    }

}
