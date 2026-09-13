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

    static func isAvailable(sessionId: UUID, in db: Database) throws -> Bool {
        guard let archive = try fetchOne(db, key: sessionId),
              let workspace = try WorkspaceRecord.fetchOne(db, key: archive.workspaceId),
              workspace.accountConnectionId == archive.connectionId, workspace.allowsCanonicalEdits,
              workspace.syncRecoveryState == nil else { return false }
        if archive.connectionId == nil { return archive.state == "saved" && archive.preparedJSON != "{}" }
        guard workspace.syncConfirmedConnectionId == archive.connectionId, archive.number != nil else { return false }
        let prepared = try SyncJSON.decoder.decode(
            [String: RecordingArchiveEncoder.Prepared].self,
            from: Data(archive.preparedJSON.utf8)
        )
        let audio = try archive.audio
        guard !audio.isEmpty, prepared.keys.allSatisfy(audio.keys.contains) else { return false }
        return try !(Bool.fetchOne(
            db,
            sql: "SELECT EXISTS (SELECT 1 FROM sync_operations WHERE entity = 'recording' AND entityId = ?)",
            arguments: [sessionId]
        ) ?? false)
    }

    static func enqueue(_ session: RecordingSessionRecord, in db: Database) throws {
        guard session.transcriptionMode == .batch,
              let meeting = try MeetingRecord.fetchOne(db, key: session.meetingId),
              let workspace = try WorkspaceRecord.fetchOne(db, key: meeting.workspaceId),
              workspace.allowsCanonicalEdits else { return }
        try Self(sessionId: session.id, meetingId: meeting.id, workspaceId: workspace.id, connectionId: workspace.accountConnectionId)
            .insert(db)
    }

    static func applyCanonical(id: UUID, workspaceId: UUID, value: SyncCanonicalPayload, in db: Database) throws {
        guard let meetingId = value.meetingId, let number = value.recordingNumber, let audio = value.audio,
              let startedAt = value.startedAt, let endedAt = value.endedAt,
              let workspace = try WorkspaceRecord.fetchOne(db, key: workspaceId), let connection = workspace.accountConnectionId else { return }
        if try RecordingSessionRecord.fetchOne(db, key: id) == nil {
            let meeting = try MeetingRecord.fetchOne(db, key: meetingId)
            try RecordingSessionRecord(
                id: id,
                meetingId: meetingId,
                startedAt: startedAt,
                endedAt: endedAt,
                duration: endedAt.timeIntervalSince(startedAt),
                offsetSeconds: max(0, startedAt.timeIntervalSince(meeting?.recordingStartedAt ?? startedAt)),
                createdAt: startedAt,
                updatedAt: endedAt,
                transcriptionMode: .batch,
                batchCompletedAt: endedAt
            ).insert(db)
        }
        let archived = try audio.mapValues { value -> RecordingArchivedAudio in
            guard let checksum = value.checksum, let manifest = value.manifest else { throw RecordingAudioStoreError.integrityMismatch }
            return try RecordingArchivedAudio(
                contentType: value.contentType.rawValue,
                size: Int64(value.size),
                checksum: checksum,
                contentURL: value.contentUrl,
                manifest: SyncJSON.decoder.decode(
                    RecordingArchiveManifest.self,
                    from: SyncJSON.encoder.encode(manifest)
                )
            )
        }
        let json = try String(decoding: SyncJSON.encoder.encode(archived), as: UTF8.self)
        try db.execute(sql: """
        INSERT INTO recording_archives(sessionId, meetingId, workspace_id, connectionId, number, audioJSON, state)
        VALUES (?, ?, ?, ?, ?, ?, 'remote')
        ON CONFLICT(sessionId) DO UPDATE SET number = excluded.number, audioJSON = excluded.audioJSON
        WHERE recording_archives.connectionId = excluded.connectionId
        """, arguments: [id, meetingId, workspaceId, connection, number, json])
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
