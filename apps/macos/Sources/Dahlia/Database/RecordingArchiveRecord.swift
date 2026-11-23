import DahliaServerAPI
import Foundation
import GRDB

/// A server recording and its durable local preparation job. Session identity stays internal to sync.
struct RecordingArchiveRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "recording_archives"

    enum CodingKeys: String, CodingKey {
        case sessionId
        case meetingId
        case workspaceId = "workspace_id"
        case connectionId
        case number
        case audioJSON
        case preparedJSON
        case state
        case retryAt
        case failureCode
        case verifiedAt
    }

    var sessionId: UUID
    var meetingId: UUID
    var workspaceId: UUID
    var connectionId: UUID?
    var number: Int?
    var audioJSON = "{}"
    var preparedJSON = "{}"
    var state = "pending"
    var retryAt: Date?
    var failureCode: String?
    var verifiedAt: Date?

    var audio: [String: RecordingArchivedAudio] {
        get throws { try SyncJSON.decoder.decode([String: RecordingArchivedAudio].self, from: Data(audioJSON.utf8)) }
    }

    /// Whether the recording is on this Mac as a saved archive; a Server's archive (`connectionId`) is not.
    static func isAvailable(sessionId: UUID, in db: Database) throws -> Bool {
        guard let archive = try fetchOne(db, key: sessionId) else { return false }
        return archive.connectionId == nil && archive.state == "saved" && archive.preparedJSON != "{}"
    }

}

struct RecordingArchiveManifest: Codable, Sendable, Equatable {
    struct Range: Codable, Sendable, Equatable {
        let startFrame: Int64
        let frameCount: Int64
        let sessionOffsetSeconds: Double
        let localeIdentifier: String
    }

    let sampleRate: Int
    let frameCount: Int64
    let ranges: [Range]
}

struct RecordingArchivedAudio: Codable, Sendable {
    let contentType: String
    let size: Int64
    let checksum: String
    let contentURL: String
    let manifest: RecordingArchiveManifest
    enum CodingKeys: String, CodingKey {
        case contentType = "content_type"
        case size, checksum, contentURL, manifest
    }
}
