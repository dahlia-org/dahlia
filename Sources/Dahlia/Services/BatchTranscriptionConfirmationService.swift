import Foundation
import GRDB

/// 同じミーティングの未確認バッチ録音を確定し、再起動後も自動復旧できる状態へ原子的に移す。
enum BatchTranscriptionConfirmationService {
    struct Result: Equatable {
        let meetingId: UUID
        let sessionIds: [UUID]
    }

    static func confirm(
        sessionId: UUID,
        localeIdentifier: String,
        retainAudioAfterBatch: Bool,
        dbQueue: DatabaseQueue
    ) async throws -> Result {
        let normalizedLocaleIdentifier = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLocaleIdentifier.isEmpty else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }

        return try await dbQueue.write { db in
            let session = try validSession(id: sessionId, db: db)
            let sessions = try unconfirmedSessions(meetingId: session.meetingId, db: db)
            let confirmedAt = Date.now
            for unconfirmedSession in sessions {
                try requireAudioRanges(sessionId: unconfirmedSession.id, db: db)
                try updateSingleRecordedLocale(
                    sessionId: unconfirmedSession.id,
                    localeIdentifier: normalizedLocaleIdentifier,
                    updatedAt: confirmedAt,
                    db: db
                )
                try markConfirmed(
                    sessionId: unconfirmedSession.id,
                    retainAudioAfterBatch: retainAudioAfterBatch,
                    confirmedAt: confirmedAt,
                    db: db
                )
            }
            return Result(meetingId: session.meetingId, sessionIds: sessions.map(\.id))
        }
    }

    private static func validSession(id: UUID, db: Database) throws -> RecordingSessionRecord {
        guard let session = try RecordingSessionRecord.fetchOne(db, key: id),
              session.transcriptionMode == .batch,
              session.endedAt != nil,
              session.batchCompletedAt == nil,
              session.batchDiscardedAt == nil,
              session.batchLastError == nil,
              session.batchLastAttemptAt == nil,
              session.batchAttemptCount == 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
        return session
    }

    private static func unconfirmedSessions(meetingId: UUID, db: Database) throws -> [RecordingSessionRecord] {
        try RecordingSessionRecord
            .filter(Column("meetingId") == meetingId)
            .filter(Column("transcriptionMode") == TranscriptionMode.batch.rawValue)
            .filter(Column("endedAt") != nil)
            .filter(Column("batchCompletedAt") == nil)
            .filter(Column("batchDiscardedAt") == nil)
            .filter(Column("batchLastError") == nil)
            .filter(Column("batchLastAttemptAt") == nil)
            .filter(Column("batchAttemptCount") == 0)
            .filter(sql: """
            EXISTS (
                SELECT 1 FROM recording_audio_segments
                WHERE recording_audio_segments.recordingSessionId = recording_sessions.id
            )
            """)
            .order(Column("startedAt").asc)
            .fetchAll(db)
    }

    private static func requireAudioRanges(sessionId: UUID, db: Database) throws {
        let rangeCount = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM recording_audio_segment_ranges
            WHERE audioSegmentId IN (
                SELECT id FROM recording_audio_segments WHERE recordingSessionId = ?
            )
            """,
            arguments: [sessionId]
        ) ?? 0
        guard rangeCount > 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    private static func updateSingleRecordedLocale(
        sessionId: UUID,
        localeIdentifier: String,
        updatedAt: Date,
        db: Database
    ) throws {
        let recordedLocales = try String.fetchAll(
            db,
            sql: """
            SELECT DISTINCT localeIdentifier
            FROM recording_audio_segment_ranges
            WHERE audioSegmentId IN (
                SELECT id FROM recording_audio_segments WHERE recordingSessionId = ?
            )
            """,
            arguments: [sessionId]
        )
        // 録音中に明示的に言語を切り替えた複数localeのrangeは保持する。
        guard recordedLocales.count <= 1 else { return }
        try db.execute(
            sql: """
            UPDATE recording_audio_segment_ranges
            SET localeIdentifier = ?, updatedAt = ?
            WHERE audioSegmentId IN (
                SELECT id FROM recording_audio_segments WHERE recordingSessionId = ?
            )
            """,
            arguments: [localeIdentifier, updatedAt, sessionId]
        )
    }

    private static func markConfirmed(
        sessionId: UUID,
        retainAudioAfterBatch: Bool,
        confirmedAt: Date,
        db: Database
    ) throws {
        // 試行時刻を確認済みマーカーとして先に保存する。処理開始時に実際の開始時刻で上書きされる。
        try db.execute(
            sql: """
            UPDATE recording_sessions
            SET retainAudioAfterBatch = ?, audioRetentionPolicy = ?,
                batchLastAttemptAt = ?, updatedAt = ?
            WHERE id = ?
            """,
            arguments: [
                retainAudioAfterBatch,
                retainAudioAfterBatch
                    ? RecordingAudioRetentionPolicy.keepInApp.rawValue
                    : RecordingAudioRetentionPolicy.deleteAfterTranscription.rawValue,
                confirmedAt,
                confirmedAt,
                sessionId,
            ]
        )
    }
}
