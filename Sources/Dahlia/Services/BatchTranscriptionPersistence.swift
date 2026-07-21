import Foundation
import GRDB

/// バッチ結果一式と完了事実を同じSQLiteトランザクションで確定する。
enum BatchTranscriptionPersistence {
    static func complete(
        sessionId: UUID,
        meetingId: UUID,
        records: [TranscriptSegmentRecord],
        completedAt: Date,
        dbQueue: DatabaseQueue
    ) throws {
        try dbQueue.write { db in
            guard let session = try RecordingSessionRecord.fetchOne(db, key: sessionId),
                  try MeetingRecord.fetchOne(db, key: meetingId) != nil else {
                throw CocoaError(.fileNoSuchFile)
            }
            let persistedCompletedAt = max(completedAt, session.batchLastAttemptAt ?? completedAt)
            _ = try TranscriptSegmentRecord
                .filter(Column("sessionId") == sessionId)
                .deleteAll(db)
            for record in records {
                try record.insert(db)
            }
            try db.execute(
                sql: """
                UPDATE recording_sessions
                SET batchCompletedAt = ?, batchLastError = NULL,
                    batchFailureKind = NULL, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [persistedCompletedAt, persistedCompletedAt, sessionId]
            )
            try db.execute(
                sql: "UPDATE meetings SET status = ?, updatedAt = ? WHERE id = ?",
                arguments: [MeetingStatus.ready.rawValue, persistedCompletedAt, meetingId]
            )
        }
    }
}
