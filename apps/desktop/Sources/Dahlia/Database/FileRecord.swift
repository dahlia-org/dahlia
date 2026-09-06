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

struct FileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "files"

    var id: UUID
    var vaultId: UUID
    var uri: String?
    var offset: Int64 = 0
    var size: Int64
    var contentType: String
    var checksum: String
    var name: String
    var metadata: FileMetadata
    var createdAt: Date
    var updatedAt: Date
    var localReference: String?
    var remoteReference: String?

    enum CodingKeys: String, CodingKey {
        case id, vaultId, uri, offset, size, checksum, name, metadata, createdAt, updatedAt, localReference, remoteReference
        case contentType = "content_type"
    }

    var contentHash: String { String(checksum.dropFirst(8)) }

    static func applyCanonical(id: UUID, vaultId: UUID, value: SyncCanonicalPayload, in db: Database) throws {
        guard let uri = value.uri, uri.hasPrefix("/Volumes/"),
              let size = value.size, size >= 0, value.offset == 0,
              let type = value.contentType, let checksum = value.checksum,
              checksum.hasPrefix("SHA-256:"), checksum.count == 72,
              checksum.dropFirst(8).allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let metadata = value.metadata, let name = value.name,
              let createdAt = value.createdAt, let updatedAt = value.updatedAt,
              let row = try Row.fetchOne(db, sql: """
              SELECT c.id, c.origin FROM vaults v JOIN dahlia_account_connections c ON c.id = v.accountConnectionId
              WHERE v.id = ?
              """, arguments: [vaultId]) else { throw SyncTransactionQueueError.invalidReceipt }
        let existing = try Self.fetchOne(db, key: id)
        let source = ScreenshotRemoteReference(
            origin: row["origin"],
            accountConnectionId: row["id"],
            fileId: id,
            contentHash: String(checksum.dropFirst(8))
        )
        try Self(
            id: id,
            vaultId: vaultId,
            uri: uri,
            size: size,
            contentType: type,
            checksum: checksum,
            name: name,
            metadata: metadata,
            createdAt: createdAt,
            updatedAt: updatedAt,
            localReference: existing?.checksum == checksum ? existing?.localReference : nil,
            remoteReference: source.jsonString()
        ).save(db)
    }
}
