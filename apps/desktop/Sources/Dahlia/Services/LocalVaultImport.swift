import Foundation
import GRDB

enum LocalVaultImportError: LocalizedError {
    case unavailable, changed, collision

    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.vaultImportUnavailable
        case .changed: L10n.vaultImportChanged
        case .collision: L10n.vaultImportCollision
        }
    }
}

enum LocalVaultImport {
    static func run(
        sourceId: UUID,
        destination: CloudVaultRecord,
        dbQueue: DatabaseQueue,
        backup: BackupService,
        api: SyncAPIClient = SyncAPIClient(session: .shared),
        screenshots: ScreenshotContentProvider = .shared
    ) async throws -> VaultRecord {
        guard sourceId != destination.vaultId else { throw LocalVaultImportError.collision }
        let connection = try await dbQueue.read { db in
            try validate(sourceId: sourceId, destination: destination, in: db)
            return try DahliaAccountConnectionRecord.fetchOne(db, key: destination.connectionId)
        }
        guard let connection, let origin = URL(string: connection.origin) else { throw LocalVaultImportError.unavailable }
        let worker = SyncWorker(dbQueue: dbQueue, apiClient: api)
        try await worker.synchronizeForTransfer(vaultId: destination.vaultId, connectionId: destination.connectionId)
        screenshots.retainOriginals(vaultIds: [sourceId], dbQueue: dbQueue)
        defer { screenshots.releaseOriginals(vaultIds: [sourceId], dbQueue: dbQueue) }
        let files = try await screenshots.prepareAccountTransfer(vaultId: sourceId, connectionId: connection.id, dbQueue: dbQueue)
        // ponytail: a database-wide fence may reject unrelated background writes; use per-Vault generations if contention matters.
        let fence = try await dbQueue.read { db in
            try validate(sourceId: sourceId, destination: destination, in: db)
            return db.totalChangesCount
        }
        let generation = try await backup.createGeneration(vaultIds: [sourceId])
        let snapshot = try await worker.importSnapshot(vaultId: destination.vaultId, connectionId: connection.id, origin: origin)
        guard let current = try await CloudVaultDiscovery.fetch(connection: connection, apiClient: api)
            .first(where: { $0.vaultId == destination.vaultId }),
            ["admin", "editor"].contains(current.role), current.organizationId == destination.organizationId else {
            throw LocalVaultImportError.unavailable
        }
        return try await dbQueue.write { db in
            guard db.totalChangesCount == fence,
                  try DahliaAccountConnectionRecord.fetchOne(db, key: connection.id) == connection else {
                throw LocalVaultImportError.changed
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
        destination: CloudVaultRecord,
        in db: Database
    ) throws {
        guard let source = try VaultRecord.fetchOne(db, key: sourceId), source.accountConnectionId == nil,
              let target = try VaultRecord.fetchOne(db, key: destination.vaultId),
              target.accountConnectionId == destination.connectionId, target.organizationId == destination.organizationId,
              target.allowsCanonicalEdits, ["admin", "editor"].contains(destination.role),
              target.syncConfirmedConnectionId == destination.connectionId, target.syncRecoveryState == nil,
              try !SyncTransactionQueue.hasPending(vaultId: sourceId, in: db),
              try !SyncTransactionQueue.hasPending(vaultId: target.id, in: db),
              try !RecordingSessionRecord.hasActiveRecording(vaultId: sourceId, in: db),
              try !RecordingSessionRecord.hasActiveRecording(vaultId: target.id, in: db) else {
            throw LocalVaultImportError.unavailable
        }
        let pendingAudio = try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM recording_archives WHERE vaultId IN (?, ?)
          AND state NOT IN ('saved', 'remote'))
        """, arguments: [sourceId, target.id]) == true
        guard !pendingAudio else { throw LocalVaultImportError.unavailable }
    }

    static func commit(
        sourceId: UUID,
        destination: CloudVaultRecord,
        snapshot: SyncResetSnapshot,
        files: [FileTransfer],
        backupPath: String,
        in db: Database
    ) throws -> VaultRecord {
        try validate(sourceId: sourceId, destination: destination, in: db)
        guard let target = try VaultRecord.fetchOne(db, key: destination.vaultId), target.syncPullCursor != nil else {
            throw LocalVaultImportError.unavailable
        }
        var moves: [(VaultRelocation.Item, UUID)] = []
        for (entity, table, remote) in [
            (SyncEntity.project, "projects", snapshot.projects),
            (.meeting, "meetings", snapshot.meetings),
            (.file, "files", snapshot.files),
        ] {
            let ids = try UUID.fetchAll(db, sql: "SELECT id FROM \(table) WHERE vaultId = ?", arguments: [sourceId])
            guard remote.isDisjoint(with: ids) else { throw LocalVaultImportError.collision }
            moves += ids.map { (.init(entity: entity, id: $0, vaultId: target.id), sourceId) }
        }
        for (table, column, remote) in [
            ("meeting_attachments", "id", snapshot.screenshots),
            ("recording_sessions", "id", snapshot.recordings),
        ] {
            let ids = try UUID.fetchAll(
                db,
                sql: "SELECT \(column) FROM \(table) WHERE meetingId IN (SELECT id FROM meetings WHERE vaultId = ?)",
                arguments: [sourceId]
            )
            guard remote.isDisjoint(with: ids) else { throw LocalVaultImportError.collision }
        }
        let record = LocalVaultImportRecord(
            id: .v7(),
            sourceVaultId: sourceId,
            destinationVaultId: target.id,
            connectionId: destination.connectionId,
            backupPath: backupPath,
            createdAt: .now
        )
        try record.insert(db)
        try ScreenshotContentProvider.installTransfers(files, vaultId: sourceId, in: db)
        try VaultRelocation.move(moves, in: db)
        // A Local revision is not a Server base revision. Only the imported entities are new.
        for (item, _) in moves {
            try db.execute(sql: "DELETE FROM sync_entity_state WHERE vaultId = ? AND entityId = ?", arguments: [target.id, item.id])
            try db.execute(
                sql: "UPDATE sync_content_state SET residentRevision = NULL WHERE vaultId = ? AND entityId = ?",
                arguments: [target.id, item.id]
            )
        }
        try SyncInitialSnapshotBuilder.enqueueContents(moves.map(\.0), vaultId: target.id, in: db)
        try db.execute(sql: """
        INSERT INTO local_vault_import_operations(operationId, importId)
        SELECT o.id, ? FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId WHERE t.vaultId = ?
        """, arguments: [record.id, target.id])
        try LocalVaultImportRecord.complete(in: db)
        return target
    }

}
