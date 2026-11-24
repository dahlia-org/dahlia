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
    /// Set by Server image analysis only when a screenshot has no shared material; such screenshots are not summary input.
    var informativeReason: String?
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

}
