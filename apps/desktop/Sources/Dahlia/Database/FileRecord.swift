import DahliaRuntimeSupport
import Foundation
import GRDB

struct FileMetadata: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case upload, screenshot }
    var source: Source
    var width: Int?
    var height: Int?
    var ocrText: String?
    var caption: String?

    enum CodingKeys: String, CodingKey {
        case source, width, height, caption
        case ocrText = "ocr_text"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encode(ocrText, forKey: .ocrText)
        try container.encode(caption, forKey: .caption)
    }
}

/// Attributes retained independently of the downloadable OCR/caption body.
struct FileStorageMetadata: Codable, Equatable, Sendable {
    var source: FileMetadata.Source
    var width: Int?
    var height: Int?
}

struct FileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "files"

    var id: UUID
    var workspaceId: UUID
    var uri: String?
    var offset: Int64 = 0
    var size: Int64
    var contentType: String
    var checksum: String
    var name: String
    var metadata: FileStorageMetadata
    var createdAt: Date
    var updatedAt: Date
    var localReference: String?
    var remoteReference: String?

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case id, uri, offset, size, checksum, name, metadata, createdAt, updatedAt, localReference, remoteReference
        case contentType = "content_type"
    }

    var contentHash: String { String(checksum.dropFirst(8)) }

    static func applyCanonical(
        id: UUID,
        workspaceId: UUID,
        value: SyncCanonicalPayload,
        preserveTextBody: Bool = false,
        in db: Database
    ) throws {
        guard let size = value.size, size >= 0,
              let type = value.contentType, let checksum = value.checksum,
              checksum.hasPrefix("SHA-256:"), checksum.count == 72,
              checksum.dropFirst(8).allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let metadata = value.metadata, let sourceType = FileMetadata.Source(rawValue: metadata.source.rawValue), let name = value.name,
              let createdAt = value.createdAt, let updatedAt = value.updatedAt,
              let row = try Row.fetchOne(db, sql: """
              SELECT c.id, c.origin FROM workspaces v JOIN dahlia_account_connections c ON c.id = v.accountConnectionId
              WHERE v.id = ?
              """, arguments: [workspaceId]) else { throw SyncTransactionQueueError.invalidReceipt }
        let existing = try Self.fetchOne(db, key: id)
        let source = ScreenshotRemoteReference(
            origin: row["origin"],
            accountConnectionId: row["id"],
            fileId: id,
            contentHash: String(checksum.dropFirst(8))
        )
        try Self(
            id: id,
            workspaceId: workspaceId,
            uri: existing?.uri,
            size: size,
            contentType: type,
            checksum: checksum,
            name: name,
            metadata: FileStorageMetadata(source: sourceType, width: metadata.width, height: metadata.height),
            createdAt: createdAt,
            updatedAt: updatedAt,
            localReference: existing?.checksum == checksum ? existing?.localReference : nil,
            remoteReference: source.jsonString()
        ).save(db)
        if !preserveTextBody, value.contentOmitted != true {
            try FileTextBodyRecord(fileId: id, ocrText: metadata.ocrText, caption: metadata.caption).save(db)
        }
    }
}
