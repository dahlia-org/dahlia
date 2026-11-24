import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

extension ScreenshotContentProvider {
    func persistCapture(_ record: MeetingScreenshotRecord, dbQueue: any DatabaseWriter) async throws {
        let workspaceId = try await dbQueue.read { db in try Self.workspaceId(meetingId: record.meetingId, in: db) }
        let stored = try await stage(record, dbQueue: dbQueue)
        try await dbQueue.write { db in
            guard try Self.workspaceId(meetingId: record.meetingId, in: db) == workspaceId else { throw ScreenshotContentError.authorizationRequired }
            try stored.insert(db)
        }
    }

    /// Complete the immutable file before publishing any reference in the domain database.
    func stage(_ record: MeetingScreenshotRecord, dbQueue: any DatabaseWriter) async throws -> MeetingScreenshotRecord {
        let original: ScreenshotContent = if let bytes = record.imageData {
            ScreenshotContent(data: bytes, mimeType: record.mimeType, variant: .original)
        } else {
            try await fileContent(id: record.originalFileId, dbQueue: dbQueue)
        }
        let hash = ScreenshotRemoteReference.digest(original.data)
        guard record.contentHash == nil || record.contentHash == hash else { throw ScreenshotContentError.integrityFailure }
        let source = ScreenshotRemoteReference(origin: "", accountConnectionId: nil, fileId: record.originalFileId, contentHash: hash)
        try fileStore(for: dbQueue).write(original, source: source, required: true)
        var stored = record.metadataOnly()
        stored.contentHash = hash
        stored.contentLength = original.data.count
        stored.mimeType = original.mimeType
        stored.localReference = try source.jsonString()
        return stored
    }

    func prepareOriginals(workspaceId: UUID, dbQueue: any DatabaseWriter, screenshotIds: [UUID]? = nil) async throws {
        let ids: [UUID] = if let screenshotIds {
            screenshotIds
        } else {
            try await dbQueue.read { db in
                try UUID.fetchAll(db, sql: "SELECT id FROM files WHERE workspace_id = ? ORDER BY id", arguments: [workspaceId])
            }
        }
        for id in ids {
            try Task.checkCancellation()
            guard let file = try await dbQueue.read({ try FileRecord.fetchOne($0, key: id) }), file.workspaceId == workspaceId else { continue }
            let content = try await fileContent(id: id, dbQueue: dbQueue, recordAccess: false)
            let source = ScreenshotRemoteReference(origin: "", accountConnectionId: nil, fileId: id, contentHash: file.contentHash)
            try fileStore(for: dbQueue).write(content, source: source, required: true, recordAccess: false)
            let reference = try source.jsonString()
            try await dbQueue.write { db in
                guard try FileRecord.fetchOne(db, key: id)?.checksum == file.checksum else { throw ScreenshotContentError.authorizationRequired }
                try db.execute(sql: "UPDATE files SET localReference = ? WHERE id = ?", arguments: [reference, id])
                try db.execute(sql: "DELETE FROM file_migration_content WHERE fileId = ?", arguments: [id])
            }
        }
    }

    func migrateLegacyImages(workspaceId: UUID, dbQueue: any DatabaseWriter) async throws {
        let ids = try await dbQueue.read { db in
            try UUID.fetchAll(db, sql: """
            SELECT f.id FROM files f JOIN file_migration_content b ON b.fileId = f.id WHERE f.workspace_id = ?
            """, arguments: [workspaceId])
        }
        try await prepareOriginals(workspaceId: workspaceId, dbQueue: dbQueue, screenshotIds: ids)
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

    nonisolated static func workspaceId(meetingId: UUID, in db: Database) throws -> UUID {
        guard let id = try UUID.fetchOne(db, sql: "SELECT workspace_id FROM meetings WHERE id = ?", arguments: [meetingId]) else {
            throw ScreenshotContentError.deleted
        }
        return id
    }
}
