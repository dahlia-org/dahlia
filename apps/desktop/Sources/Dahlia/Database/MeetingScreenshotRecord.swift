import DahliaRuntimeSupport
import Foundation
import GRDB

/// スクリーンショットを表す GRDB レコード。
struct MeetingScreenshotRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "meeting_images"

    var id: UUID
    var fileId: UUID?
    var meetingId: UUID
    var sessionId: UUID?
    var capturedAt: Date
    var imageData: Data?
    var mimeType: String
    var ocrText: String?
    var caption: String?
    var contentHash: String?
    var contentLength: Int?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var remoteReference: String?
    var localReference: String?

    static let metadataSelection = """
    id, fileId, meetingId, sessionId, capturedAt, NULL AS imageData, mimeType, ocrText, caption,
    contentHash, contentLength, pixelWidth, pixelHeight, remoteReference, localReference
    """

    var remoteSource: ScreenshotRemoteReference? {
        guard let remoteReference else { return nil }
        return try? JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(remoteReference.utf8))
    }

    var localSource: ScreenshotRemoteReference? {
        guard let localReference else { return nil }
        return try? JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(localReference.utf8))
    }

    func metadataOnly() -> Self {
        var result = self
        result.imageData = nil
        result.contentLength = contentLength ?? imageData?.count
        return result
    }

    var originalFileId: UUID { fileId ?? id }

    static func fetchOne(_ db: Database, key: UUID) throws -> Self? {
        try fetchOne(db, sql: "SELECT * FROM meeting_images WHERE id = ?", arguments: [key])
    }

    func insert(_ db: Database) throws {
        guard imageData == nil, localReference != nil || remoteReference != nil,
              let contentHash, let contentLength,
              let vaultId = try MeetingRecord.fetchOne(db, key: meetingId)?.vaultId else {
            throw ScreenshotContentError.unavailable
        }
        if try FileRecord.fetchOne(db, key: originalFileId) == nil {
            try FileRecord(
                id: originalFileId,
                vaultId: vaultId,
                size: Int64(contentLength),
                contentType: mimeType,
                checksum: "SHA-256:" + contentHash,
                name: "capture.\(mimeType.split(separator: "/").last ?? "bin")",
                metadata: FileMetadata(source: .screenshot, width: pixelWidth, height: pixelHeight, ocrText: ocrText, caption: caption),
                createdAt: capturedAt,
                updatedAt: capturedAt,
                localReference: localReference,
                remoteReference: remoteReference
            ).insert(db)
        }
        try MeetingFileRecord(
            id: id,
            meetingId: meetingId,
            fileId: originalFileId,
            capturedAt: capturedAt,
            sessionId: sessionId,
            createdAt: capturedAt
        ).insert(db)
    }

    func update(_ db: Database) throws {
        guard var file = try FileRecord.fetchOne(db, key: originalFileId) else { throw ScreenshotContentError.deleted }
        file.metadata.ocrText = ocrText
        file.metadata.caption = caption
        file.updatedAt = Date()
        try file.update(db)
    }
}
