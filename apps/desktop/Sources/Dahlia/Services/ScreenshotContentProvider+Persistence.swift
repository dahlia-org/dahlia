import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

extension ScreenshotContentProvider {
    func persistCapture(_ record: MeetingScreenshotRecord, dbQueue: DatabaseQueue) async throws {
        activeFileWork += 1
        defer { activeFileWork -= 1 }
        let target = try await dbQueue.read { db in try Self.target(meetingId: record.meetingId, in: db) }
        let stored = try await stage(record, connectionId: target.connectionId, dbQueue: dbQueue)
        try await dbQueue.write { db in
            guard try Self.target(meetingId: record.meetingId, in: db) == target else { throw ScreenshotContentError.authorizationRequired }
            try stored.insert(db)
            if target.connectionId != nil {
                let attachment = try SyncScreenshotAttachmentReference(stored)
                let file = try SyncInitialSnapshotBuilder.screenshotOperation(stored, action: .upsert)
                let link = try SyncInitialSnapshotBuilder.meetingFileOperation(stored)
                try SyncTransactionRecorder.record(
                    vaultId: target.vaultId,
                    operations: [file, link],
                    screenshotAttachments: [file.id: attachment],
                    in: db
                )
            }
        }
    }

    /// Complete the immutable file before publishing any reference in the domain database.
    func stage(
        _ record: MeetingScreenshotRecord,
        connectionId: UUID?,
        dbQueue: DatabaseQueue
    ) async throws -> MeetingScreenshotRecord {
        let origin = try await origin(connectionId: connectionId, dbQueue: dbQueue)
        let original: ScreenshotContent = if let bytes = record.imageData {
            ScreenshotContent(data: bytes, mimeType: record.mimeType, variant: .original)
        } else {
            try await fileContent(id: record.originalFileId, dbQueue: dbQueue)
        }
        let hash = ScreenshotRemoteReference.digest(original.data)
        guard record.contentHash == nil || record.contentHash == hash else { throw ScreenshotContentError.integrityFailure }
        let source = ScreenshotRemoteReference(origin: origin, accountConnectionId: connectionId, fileId: record.originalFileId, contentHash: hash)
        try fileStore(for: dbQueue).write(original, source: source, required: true)
        var stored = record.metadataOnly()
        stored.contentHash = hash
        stored.contentLength = original.data.count
        stored.mimeType = original.mimeType
        stored.localReference = try source.jsonString()
        return stored
    }

    private func origin(connectionId: UUID?, dbQueue: DatabaseQueue) async throws -> String {
        guard let connectionId else { return "" }
        guard let origin = try await dbQueue.read({ try DahliaAccountConnectionRecord.fetchOne($0, key: connectionId)?.origin }) else {
            throw ScreenshotContentError.authorizationRequired
        }
        return origin
    }

    func prepareAccountTransfer(vaultId: UUID, connectionId: UUID?, dbQueue: DatabaseQueue) async throws -> [FileTransfer] {
        activeFileWork += 1
        defer { activeFileWork -= 1 }
        let origin = try await origin(connectionId: connectionId, dbQueue: dbQueue)
        let records = try await dbQueue.read { try FileRecord.filter(Column("vaultId") == vaultId).fetchAll($0) }
        var transfers: [FileTransfer] = []
        for file in records {
            let content = try await fileContent(id: file.id, dbQueue: dbQueue)
            let source = ScreenshotRemoteReference(origin: origin, accountConnectionId: connectionId, fileId: file.id, contentHash: file.contentHash)
            try fileStore(for: dbQueue).write(content, source: source, required: true)
            try transfers.append(FileTransfer(file: file, reference: source.jsonString()))
        }
        return transfers
    }

    nonisolated static func installTransfers(_ transfers: [FileTransfer], vaultId: UUID, in db: Database) throws {
        guard try FileRecord.filter(Column("vaultId") == vaultId).fetchCount(db) == transfers.count else { throw ScreenshotContentError.unavailable }
        for transfer in transfers {
            try db.execute(sql: """
            UPDATE files SET localReference = ?, remoteReference = NULL, uri = NULL
            WHERE id = ? AND vaultId = ? AND checksum = ? AND localReference IS ? AND remoteReference IS ?
            """, arguments: [
                transfer.reference,
                transfer.file.id,
                vaultId,
                transfer.file.checksum,
                transfer.file.localReference,
                transfer.file.remoteReference,
            ])
            guard db.changesCount == 1 else { throw ScreenshotContentError.unavailable }
            try db.execute(sql: "DELETE FROM file_migration_content WHERE fileId = ?", arguments: [transfer.file.id])
        }
    }

    func prepareOriginals(vaultId: UUID, dbQueue: DatabaseQueue, screenshotIds: [UUID]? = nil) async throws {
        activeFileWork += 1
        defer { activeFileWork -= 1 }
        try await migrateLegacyAttachments(vaultId: vaultId, dbQueue: dbQueue)
        let ids = try await dbQueue.read { db in
            try UUID.fetchAll(db, sql: "SELECT id FROM files WHERE vaultId = ? ORDER BY id", arguments: [vaultId])
        }
        for id in ids where screenshotIds?.contains(id) ?? true {
            try Task.checkCancellation()
            guard let file = try await dbQueue.read({ try FileRecord.fetchOne($0, key: id) }), file.vaultId == vaultId else { continue }
            let connectionId = try await dbQueue.read { try VaultRecord.fetchOne($0, key: vaultId)?.accountConnectionId }
            let origin = try await origin(connectionId: connectionId, dbQueue: dbQueue)
            let content = try await fileContent(id: id, dbQueue: dbQueue)
            let source = ScreenshotRemoteReference(origin: origin, accountConnectionId: connectionId, fileId: id, contentHash: file.contentHash)
            try fileStore(for: dbQueue).write(content, source: source, required: true)
            let reference = try source.jsonString()
            try await dbQueue.write { db in
                guard try VaultRecord.fetchOne(db, key: vaultId)?.accountConnectionId == connectionId,
                      try FileRecord.fetchOne(db, key: id)?.checksum == file.checksum else { throw ScreenshotContentError.authorizationRequired }
                try db.execute(sql: "UPDATE files SET localReference = ? WHERE id = ?", arguments: [reference, id])
                try db.execute(sql: "DELETE FROM file_migration_content WHERE fileId = ?", arguments: [id])
            }
        }
    }

    func migrateLegacyImages(vaultId: UUID, dbQueue: DatabaseQueue) async throws {
        let ids = try await dbQueue.read { db in
            try UUID.fetchAll(db, sql: """
            SELECT f.id FROM files f JOIN file_migration_content b ON b.fileId = f.id WHERE f.vaultId = ?
            """, arguments: [vaultId])
        }
        try await prepareOriginals(vaultId: vaultId, dbQueue: dbQueue, screenshotIds: ids)
    }

    private func migrateLegacyAttachments(vaultId: UUID, dbQueue: DatabaseQueue) async throws {
        while true {
            try Task.checkCancellation()
            let row = try await dbQueue.read { db in
                try Row.fetchOne(db, sql: """
                SELECT o.id, o.entityId, o.attachmentMimeType, o.attachmentSHA256,
                    coalesce(o.attachmentBytes, b.imageData) AS bytes, c.id AS connectionId, c.origin
                FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
                JOIN dahlia_account_connections c ON c.id = t.connectionId
                LEFT JOIN file_migration_content b ON b.fileId = o.entityId
                WHERE t.vaultId = ? AND o.attachmentMimeType IS NOT NULL AND o.attachmentReference IS NULL
                ORDER BY t.sequence, o.position LIMIT 1
                """, arguments: [vaultId])
            }
            guard let row else { return }
            guard let bytes: Data = row["bytes"], let hash: String = row["attachmentSHA256"],
                  ScreenshotRemoteReference.digest(bytes) == hash else { throw ScreenshotContentError.integrityFailure }
            let source = ScreenshotRemoteReference(
                origin: row["origin"],
                accountConnectionId: row["connectionId"],
                fileId: row["entityId"],
                contentHash: hash
            )
            try fileStore(for: dbQueue).write(
                ScreenshotContent(data: bytes, mimeType: row["attachmentMimeType"], variant: .original),
                source: source,
                required: true
            )
            let operationId: UUID = row["id"]
            let reference = try source.jsonString()
            try await dbQueue.write { db in
                try db.execute(sql: """
                UPDATE sync_operations SET attachmentReference = ?, attachmentBytes = NULL
                WHERE id = ? AND attachmentReference IS NULL AND attachmentSHA256 = ?
                """, arguments: [reference, operationId, hash])
            }
        }
    }

    func attachment(operationId: UUID, dbQueue: DatabaseQueue) async throws -> SyncScreenshotAttachment? {
        activeFileWork += 1
        defer { activeFileWork -= 1 }
        let vaultId = try await dbQueue.read { db in
            try UUID.fetchOne(db, sql: """
            SELECT t.vaultId FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
            WHERE o.id = ? AND o.attachmentMimeType IS NOT NULL
            """, arguments: [operationId])
        }
        guard let vaultId else { return nil }
        try await migrateLegacyAttachments(vaultId: vaultId, dbQueue: dbQueue)
        let row = try await dbQueue.read { db in
            try Row.fetchOne(db, sql: """
            SELECT o.attachmentReference, o.attachmentMimeType, o.attachmentSHA256, c.id AS connectionId, c.origin
            FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
            JOIN dahlia_account_connections c ON c.id = t.connectionId WHERE o.id = ?
            """, arguments: [operationId])
        }
        guard let row, let reference: String = row["attachmentReference"] else { throw ScreenshotContentError.unavailable }
        let source = try JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(reference.utf8))
        guard source.origin == row["origin"] as String, source.accountConnectionId == row["connectionId"] as UUID,
              source.contentHash == row["attachmentSHA256"] as String else { throw ScreenshotContentError.integrityFailure }
        guard let content = try fileStore(for: dbQueue).read(source, variant: .original) else { throw ScreenshotContentError.unavailable }
        return SyncScreenshotAttachment(mimeType: row["attachmentMimeType"], bytes: content.data)
    }

    func trimFiles(dbQueue: DatabaseQueue, budget: Int? = nil) throws {
        // ponytail: pause eviction during publication or account moves; use per-file leases if contention becomes material.
        guard activeFileWork == 0, retainedVaults.withLock({ $0.values.allSatisfy(\.isEmpty) }) else { return }
        let files = try fileStore(for: dbQueue)
        try dbQueue.write { db in
            guard self.retainedVaults.withLock({ $0.values.allSatisfy(\.isEmpty) }) else { return }
            let references = try String.fetchAll(db, sql: """
            SELECT coalesce(f.localReference, f.remoteReference) FROM files f JOIN vaults v ON v.id = f.vaultId
            WHERE coalesce(f.localReference, f.remoteReference) IS NOT NULL AND (
                (f.localReference IS NOT NULL AND f.remoteReference IS NOT f.localReference)
                OR v.accountConnectionId IS NULL OR v.accountConnectionId IS NOT v.syncConfirmedConnectionId
                OR v.syncPullCursor IS NULL OR v.syncRecoveryState IS NOT NULL
                OR EXISTS(SELECT 1 FROM sync_transactions t WHERE t.vaultId = v.id)
                OR NOT EXISTS(SELECT 1 FROM sync_entity_state e WHERE e.vaultId = v.id
                    AND e.entity = 'file' AND e.entityId = f.id AND e.confirmedRevision > 0)
            )
            UNION SELECT attachmentReference FROM sync_operations WHERE attachmentReference IS NOT NULL
            """)
            let keys = try Set(references.map {
                try JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data($0.utf8)).cacheKey(variant: .original)
            })
            try files.trim(budget: budget, protecting: keys)
        }
    }

    nonisolated static func install(_ stored: MeetingScreenshotRecord, replacing expected: MeetingScreenshotRecord, in db: Database) throws {
        try db.execute(sql: """
        UPDATE files SET localReference = ?, checksum = ?, size = ?, content_type = ?
        WHERE id = ? AND checksum IS ? AND remoteReference IS ? AND localReference IS ?
        """, arguments: [
            stored.localReference,
            stored.contentHash.map { "SHA-256:" + $0 },
            stored.contentLength,
            stored.mimeType,
            stored.originalFileId,
            expected.contentHash.map { "SHA-256:" + $0 },
            expected.remoteReference,
            expected.localReference,
        ])
        guard db.changesCount == 1 else { throw ScreenshotContentError.unavailable }
        try db.execute(sql: "DELETE FROM file_migration_content WHERE fileId = ?", arguments: [stored.originalFileId])
    }

    nonisolated static func target(meetingId: UUID, in db: Database) throws -> ScreenshotCaptureTarget {
        guard let row = try Row.fetchOne(db, sql: """
        SELECT v.id, v.accountConnectionId FROM meetings m JOIN vaults v ON v.id = m.vaultId WHERE m.id = ?
        """, arguments: [meetingId]) else { throw ScreenshotContentError.deleted }
        return ScreenshotCaptureTarget(vaultId: row["id"], connectionId: row["accountConnectionId"])
    }
}

struct ScreenshotCaptureTarget: Equatable, Sendable {
    let vaultId: UUID
    let connectionId: UUID?
}

struct FileTransfer: Sendable {
    let file: FileRecord
    let reference: String
}
