import DahliaRuntimeSupport
import Foundation
import GRDB

/// スクリーンショットを表す GRDB レコード。
struct MeetingScreenshotRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "screenshots"

    var id: UUID
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

    static let metadataSelection = """
    id, meetingId, sessionId, capturedAt, NULL AS imageData, mimeType, ocrText, caption,
    contentHash, contentLength, pixelWidth, pixelHeight, remoteReference
    """

    var remoteSource: ScreenshotRemoteReference? {
        guard let remoteReference else { return nil }
        return try? JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(remoteReference.utf8))
    }

    func metadataOnly() -> Self {
        var result = self
        result.imageData = nil
        result.contentLength = contentLength ?? imageData?.count
        return result
    }

    func requiredOriginal() throws -> Data {
        guard let imageData else { throw SyncTransactionQueueError.invalidReceipt }
        return imageData
    }

    static func applyCanonical(id: UUID, vaultId: UUID, value: SyncCanonicalPayload, in db: Database) throws {
        guard let meetingId = value.meetingId, let capturedAt = value.capturedAt,
              let mimeType = value.contentType, let hash = value.contentHash,
              hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
            throw SyncTransactionQueueError.invalidReceipt
        }
        var existingHash = try String.fetchOne(db, sql: "SELECT contentHash FROM screenshots WHERE id = ?", arguments: [id])
        if existingHash == nil {
            existingHash = try Data.fetchOne(db, sql: "SELECT imageData FROM screenshots WHERE id = ?", arguments: [id])
                .map(ScreenshotRemoteReference.digest)
        }
        let preservesOriginal = existingHash == hash
        let origin = try String.fetchOne(db, sql: """
        SELECT c.origin FROM vaults v JOIN dahlia_account_connections c ON c.id = v.accountConnectionId
        WHERE v.id = ?
        """, arguments: [vaultId])
        let source = try origin.map {
            try ScreenshotRemoteReference(origin: $0, vaultId: vaultId, meetingId: meetingId, screenshotId: id, contentHash: hash).jsonString()
        }
        try db.execute(sql: """
        INSERT INTO screenshots(id, meetingId, capturedAt, imageData, mimeType, ocrText, caption, contentHash, contentLength, remoteReference)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET capturedAt = excluded.capturedAt,
            imageData = CASE WHEN ? THEN screenshots.imageData ELSE NULL END,
            mimeType = excluded.mimeType, ocrText = excluded.ocrText, caption = excluded.caption,
            contentHash = excluded.contentHash,
            contentLength = coalesce(excluded.contentLength, length(imageData)), remoteReference = excluded.remoteReference
        """, arguments: [
            id,
            meetingId,
            capturedAt,
            nil,
            mimeType,
            value.ocrText,
            value.caption,
            hash,
            value.contentLength,
            source,
            preservesOriginal,
        ])
    }
}
