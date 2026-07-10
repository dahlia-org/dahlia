import Foundation
import GRDB

/// バッチ正本の言語を確定し、再起動後も自動復旧できる状態へ原子的に移す。
enum BatchTranscriptionConfirmationService {
    static func confirm(
        sessionId: UUID,
        localeIdentifier: String,
        dbQueue: DatabaseQueue
    ) async throws -> UUID {
        let normalizedLocaleIdentifier = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLocaleIdentifier.isEmpty else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }

        return try await dbQueue.write { db in
            guard let session = try RecordingSessionRecord.fetchOne(db, key: sessionId),
                  session.transcriptionMode == .batch,
                  session.endedAt != nil,
                  session.batchCompletedAt == nil,
                  session.batchDiscardedAt == nil,
                  session.batchLastError == nil,
                  session.batchAttemptCount == 0
            else {
                throw CocoaError(.fileNoSuchFile)
            }

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

            let confirmedAt = Date.now
            try db.execute(
                sql: """
                UPDATE recording_audio_ranges
                SET localeIdentifier = ?, updatedAt = ?
                WHERE audioFileId IN (
                    SELECT id FROM recording_audio_files WHERE recordingSessionId = ?
                )
                """,
                arguments: [normalizedLocaleIdentifier, confirmedAt, sessionId]
            )
            // 試行時刻を確認済みマーカーとして先に保存する。処理開始時に実際の開始時刻で上書きされる。
            try db.execute(
                sql: """
                UPDATE recording_sessions
                SET batchLastAttemptAt = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [confirmedAt, confirmedAt, sessionId]
            )
            return session.meetingId
        }
    }
}
