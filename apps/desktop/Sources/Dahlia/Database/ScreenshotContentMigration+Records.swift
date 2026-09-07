import Foundation
import GRDB

/// Freeze the v45 row encoding independently of the current runtime schema.
extension ScreenshotContentMigration {
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

    }
}
