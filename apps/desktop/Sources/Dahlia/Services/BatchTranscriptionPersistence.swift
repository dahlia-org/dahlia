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
                  session.meetingId == meetingId,
                  try MeetingRecord.fetchOne(db, key: meetingId) != nil else {
                throw CocoaError(.fileNoSuchFile)
            }
            guard session.batchDiscardedAt == nil,
                  session.batchCompletedAt == nil || session.isBatchRetranscriptionPending else {
                throw CancellationError()
            }
            let persistedCompletedAt = max(completedAt, session.batchLastAttemptAt ?? completedAt)
            let deletedIds = try UUID.fetchAll(
                db,
                sql: "SELECT id FROM transcript_segments WHERE sessionId = ?",
                arguments: [sessionId]
            )
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
            guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: meetingId)
            try SyncTransactionRecorder.record(
                vaultId: meeting.vaultId,
                operations: [
                    patch,
                    SyncInitialSnapshotBuilder.meetingOperation(meeting, action: .update),
                ],
                transcriptSegments: [patch.id: records.map(SyncTranscriptPatchSegment.init)],
                transcriptDeletions: [patch.id: deletedIds],
                in: db
            )
        }
    }
}
