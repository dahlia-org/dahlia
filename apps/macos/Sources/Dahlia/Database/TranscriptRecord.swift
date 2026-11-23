import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

/// Latest descriptor only.
struct TranscriptRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "transcripts"
    var meetingId: UUID
    var sessionId: UUID?
    var infoJSON: String

    var info: TranscriptInfo {
        get throws { try SyncJSON.decoder.decode(TranscriptInfo.self, from: Data(infoJSON.utf8)) }
    }

    init(meetingId: UUID, sessionId: UUID? = nil, info: TranscriptInfo) throws {
        self.meetingId = meetingId
        self.sessionId = sessionId
        let data = try SyncJSON.encoder.encode(info)
        var stored = try SyncJSON.decoder.decode([String: JSONValue].self, from: data)
        stored.removeValue(forKey: "status")
        self.infoJSON = try String(decoding: SyncJSON.encoder.encode(stored), as: UTF8.self)
    }

    static func current(_ meetingId: UUID, in db: Database) throws -> TranscriptInfo? {
        guard var info = try fetchOne(db, key: meetingId)?.info else { return nil }
        if try db.columns(in: "transcript_segments").contains(where: { $0.name == "createdAt" }),
           try [.ready, .stale, .empty].contains(TextContentAccess.availability(entity: .transcript, id: meetingId, in: db).state) {
            info.latestSegmentCreatedAt = try Date.fetchOne(
                db,
                sql: "SELECT MAX(createdAt) FROM transcript_segments WHERE meetingId = ?",
                arguments: [meetingId]
            )
        }
        return info
    }

    static func beginLive(_ session: RecordingSessionRecord, liveDraft: Bool = false, in db: Database) throws {
        guard session.transcriptionMode == .realtime || liveDraft else { return }
        try TextContentAccess.requireComplete(entity: .transcript, id: session.meetingId, in: db)
        let previousRecord = try fetchOne(db, key: session.meetingId)
        let previous = try previousRecord?.info
        if let previousSessionId = previousRecord?.sessionId, previousSessionId != session.id,
           let previousSession = try RecordingSessionRecord.fetchOne(db, key: previousSessionId), previousSession.endedAt == nil {
            throw TextContentError.changed
        }
        let hasText = try TranscriptSegmentRecord.filter(Column("meetingId") == session.meetingId).fetchCount(db) > 0
        guard try RecordingSessionRecord.filter(Column("meetingId") == session.meetingId)
            .filter(Column("id") != session.id).filter(Column("endedAt") == nil)
            .filter(sql: RecordingSessionRecord.hasRecordingEvidenceSQL).fetchCount(db) == 0 else { throw TextContentError.changed }
        guard liveDraft || !hasText || previous?.metadata?.usesAppleModel("apple-speech-live") == true else {
            throw TranscriptVersionError.fullTranscriptionUnavailable
        }
        var metadata = TranscriptMetadata(provider: "apple", model: "apple-speech-live", runs: hasText ? previous?.metadata?.runs ?? [] : [])
        let startedAt = Date.now
        metadata.runs.append(.init(startedAt: startedAt, recordingSessionId: session.id))
        let info = TranscriptInfo(id: .v7(), startedAt: startedAt, endedAt: nil, metadata: metadata)
        try Self(meetingId: session.meetingId, sessionId: session.id, info: info).save(db)
    }

    static func finishLive(
        meetingId: UUID,
        sessionId: UUID,
        at date: Date?,
        in db: Database
    ) throws {
        guard let record = try fetchOne(db, key: meetingId), record.sessionId == sessionId else { return }
        var info = try record.info
        guard info.endedAt == nil else { return }
        info.endedAt = date
        if let last = info.metadata?.runs.indices.last { info.metadata?.runs[last].completedAt = info.endedAt }
        try Self(meetingId: meetingId, info: info).save(db)
    }
}

enum TranscriptVersionError: LocalizedError {
    case fullTranscriptionUnavailable
    var errorDescription: String? { L10n.transcriptFullTranscriptionUnavailable }
}
