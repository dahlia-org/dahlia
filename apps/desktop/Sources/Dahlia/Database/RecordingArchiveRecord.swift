import Foundation
import GRDB

/// A server recording and its durable local preparation job. Session identity stays internal to sync.
struct RecordingArchiveRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "recording_archives"
    var sessionId: UUID
    var meetingId: UUID
    var vaultId: UUID
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
              let vault = try VaultRecord.fetchOne(db, key: archive.vaultId),
              vault.accountConnectionId == archive.connectionId, vault.allowsCanonicalEdits,
              vault.syncRecoveryState == nil else { return false }
        if archive.connectionId == nil { return archive.state == "saved" && archive.preparedJSON != "{}" }
        return vault.syncConfirmedConnectionId == archive.connectionId && archive.number != nil && archive.audioJSON != "{}"
    }

    static func enqueue(_ session: RecordingSessionRecord, in db: Database) throws {
        guard session.transcriptionMode == .batch,
              let meeting = try MeetingRecord.fetchOne(db, key: session.meetingId),
              let vault = try VaultRecord.fetchOne(db, key: meeting.vaultId),
              vault.allowsCanonicalEdits else { return }
        try Self(sessionId: session.id, meetingId: meeting.id, vaultId: vault.id, connectionId: vault.accountConnectionId)
            .insert(db)
    }

    static func applyCanonical(id: UUID, vaultId: UUID, value: SyncCanonicalPayload, in db: Database) throws {
        guard let meetingId = value.meetingId, let number = value.recordingNumber, let audio = value.audio,
              let startedAt = value.startedAt, let endedAt = value.endedAt,
              let vault = try VaultRecord.fetchOne(db, key: vaultId), let connection = vault.accountConnectionId else { return }
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
        let json = try String(decoding: SyncJSON.encoder.encode(audio), as: UTF8.self)
        try db.execute(sql: """
        INSERT INTO recording_archives(sessionId, meetingId, vaultId, connectionId, number, audioJSON, state)
        VALUES (?, ?, ?, ?, ?, ?, 'remote')
        ON CONFLICT(sessionId) DO UPDATE SET number = excluded.number, audioJSON = excluded.audioJSON
        WHERE recording_archives.connectionId = excluded.connectionId
        """, arguments: [id, meetingId, vaultId, connection, number, json])
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
