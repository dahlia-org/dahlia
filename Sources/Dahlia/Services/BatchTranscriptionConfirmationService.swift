import Foundation
import GRDB

/// バッチ正本の言語を確定し、再起動後も自動復旧できる状態へ原子的に移す。
enum BatchTranscriptionConfirmationService {
    static func confirm(
        sessionId: UUID,
        localeIdentifier: String,
        retainAudioAfterBatch: Bool,
        dbQueue: DatabaseQueue
    ) async throws -> UUID {
        let normalizedLocaleIdentifier = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLocaleIdentifier.isEmpty else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }

        return try await dbQueue.write { db in
            let session = try validSession(id: sessionId, db: db)
            try requireAudioRanges(sessionId: sessionId, db: db)
            let confirmedAt = Date.now
            try updateSingleRecordedLocale(
                sessionId: sessionId,
                localeIdentifier: normalizedLocaleIdentifier,
                updatedAt: confirmedAt,
                db: db
            )
            try markConfirmed(
                sessionId: sessionId,
                retainAudioAfterBatch: retainAudioAfterBatch,
                confirmedAt: confirmedAt,
                db: db
            )
            return session.meetingId
        }
    }

    private static func validSession(id: UUID, db: Database) throws -> RecordingSessionRecord {
        guard let session = try RecordingSessionRecord.fetchOne(db, key: id),
              session.transcriptionMode == .batch,
              session.endedAt != nil,
              session.batchCompletedAt == nil,
              session.batchDiscardedAt == nil,
              session.batchLastError == nil,
              session.batchAttemptCount == 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
        return session
    }

    private static func requireAudioRanges(sessionId: UUID, db: Database) throws {
        let rangeCount = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM recording_audio_ranges
            WHERE audioFileId IN (
                SELECT id FROM recording_audio_files WHERE recordingSessionId = ?
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
            FROM recording_audio_ranges
            WHERE audioFileId IN (
                SELECT id FROM recording_audio_files WHERE recordingSessionId = ?
            )
            """,
            arguments: [sessionId]
        )
        // 録音中に明示的に言語を切り替えた複数localeのrangeは保持する。
        guard recordedLocales.count <= 1 else { return }
        try db.execute(
            sql: """
            UPDATE recording_audio_ranges
            SET localeIdentifier = ?, updatedAt = ?
            WHERE audioFileId IN (
                SELECT id FROM recording_audio_files WHERE recordingSessionId = ?
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
            SET retainAudioAfterBatch = ?, batchLastAttemptAt = ?, updatedAt = ?
            WHERE id = ?
            """,
            arguments: [retainAudioAfterBatch, confirmedAt, confirmedAt, sessionId]
        )
    }
}
