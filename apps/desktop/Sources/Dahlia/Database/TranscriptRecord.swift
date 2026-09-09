import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

/// Latest descriptor only. Historical transcript bodies are a Server responsibility.
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

    static func applyCanonical(meetingId: UUID, info: TranscriptInfo, in db: Database) throws {
        let previous = try fetchOne(db, key: meetingId)
        let sessionId = try previous?.info.id == info.id ? previous?.sessionId : nil
        try Self(meetingId: meetingId, sessionId: sessionId, info: info).save(db)
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
        if liveDraft, hasText, previous?.metadata?.usesAppleModel("apple-speech-live") != true {
            try enqueueSnapshot(meetingId: session.meetingId, info: info, in: db)
            return
        }
        let operation = try mutation(meetingId: session.meetingId, info: info, mode: hasText ? "append" : "replace")
        if let meeting = try MeetingRecord.fetchOne(db, key: session.meetingId) {
            try SyncTransactionRecorder.record(vaultId: meeting.vaultId, operations: [operation], in: db)
        }
    }

    static func finishLive(
        meetingId: UUID,
        sessionId: UUID,
        at date: Date?,
        deletions: [UUID] = [],
        in db: Database
    ) throws {
        guard let record = try fetchOne(db, key: meetingId), record.sessionId == sessionId else { return }
        var info = try record.info
        guard info.endedAt == nil else { return }
        info.endedAt = date
        if let last = info.metadata?.runs.indices.last { info.metadata?.runs[last].completedAt = info.endedAt }
        try Self(meetingId: meetingId, info: info).save(db)
        if let meeting = try MeetingRecord.fetchOne(db, key: meetingId) {
            let operation = try mutation(meetingId: meetingId, info: info, mode: "append")
            try SyncTransactionRecorder.record(
                vaultId: meeting.vaultId,
                operations: [operation],
                transcriptDeletions: [operation.id: deletions],
                in: db
            )
        }
    }

    static func mutation(meetingId: UUID, info: TranscriptInfo, mode: String) throws -> SyncOperationDraft {
        try SyncOperationDraft(
            entity: .transcript,
            action: .patch,
            entityId: meetingId,
            payloadJSON: SyncJSON.encoder.encode(TranscriptMutation(info: info, mode: mode))
        )
    }

    static func reapplySnapshots(meetingIds: [UUID], in db: Database) throws {
        for meetingId in meetingIds {
            let previous = try fetchOne(db, key: meetingId)
            var info = try previous?.info ?? TranscriptInfo(id: .v7(), startedAt: nil, endedAt: nil, metadata: nil)
            info.id = .v7()
            info.version = nil
            info.syncRevision = nil
            try Self(meetingId: meetingId, sessionId: previous?.sessionId, info: info).save(db)
            try enqueueSnapshot(meetingId: meetingId, info: info, reapplyOnCurrentRevision: true, in: db)
        }
    }

    /// Freeze a complete body into the existing durable upload queue without materializing it in Swift.
    static func enqueueSnapshot(
        meetingId: UUID,
        info: TranscriptInfo,
        allowAfterReset: Bool = false,
        connectionId: UUID? = nil,
        reapplyOnCurrentRevision: Bool = false,
        in db: Database
    ) throws {
        try TextContentAccess.requireComplete(entity: .transcript, id: meetingId, in: db)
        guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { return }
        let operation = try mutation(meetingId: meetingId, info: info, mode: "replace")
        guard try SyncTransactionRecorder.record(
            vaultId: meeting.vaultId,
            operations: [operation],
            allowAfterReset: allowAfterReset,
            connectionIdOverride: connectionId,
            reapplyOnCurrentRevision: reapplyOnCurrentRevision,
            in: db
        ) != nil else { return }
        try copySnapshot(meetingId: meetingId, operationId: operation.id, in: db)
    }

    static func copySnapshot(meetingId: UUID, operationId: UUID, in db: Database) throws {
        let currentSchema = try db.columns(in: "transcript_segments").contains { $0.name == "createdAt" }
        let startedAt = currentSchema ? "s.startedAt" : "s.startTime"
        let endedAt = currentSchema ? "s.endedAt" : "s.endTime"
        try db.execute(sql: """
        INSERT INTO sync_transcript_patch_items(operationId, position, action, segmentId, startTime, endTime, text,
            isConfirmed, audioSource, speakerLabel\(currentSchema ? ", createdAt" : ""))
        SELECT ?, row_number() OVER (ORDER BY \(startedAt), s.id) - 1, 'upsert', s.id, \(startedAt), \(endedAt), b.text,
            1, s.audioSource, s.speakerLabel\(currentSchema ? ", s.createdAt" : "")
        FROM transcript_segments s JOIN transcript_segment_bodies b ON b.segmentId = s.id
        WHERE s.meetingId = ? \(currentSchema ? "" : "AND s.isConfirmed = 1")
        """, arguments: [operationId, meetingId])
    }
}

struct TranscriptMutation: Codable, Sendable {
    struct Descriptor: Codable, Sendable {
        var id: UUID
        var startedAt: Date?
        var endedAt: Date?
        var metadata: TranscriptMetadata?
    }

    var transcript: Descriptor
    var mode: String

    init(info: TranscriptInfo, mode: String) {
        self.transcript = Descriptor(
            id: info.id,
            startedAt: info.startedAt,
            endedAt: info.endedAt,
            metadata: info.metadata
        )
        self.mode = mode
    }
}

enum TranscriptVersionError: LocalizedError {
    case fullTranscriptionUnavailable
    var errorDescription: String? { L10n.transcriptFullTranscriptionUnavailable }
}
