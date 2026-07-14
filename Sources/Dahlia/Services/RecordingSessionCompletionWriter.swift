import Foundation
import GRDB

/// 録音セッション終了と meeting 合計時間の更新を、同一 transaction 内で一元的に行う。
enum RecordingSessionCompletionWriter {
    struct Request {
        let recordingSessionId: UUID
        let meetingId: UUID
        let endedAt: Date
        let duration: TimeInterval
        let updatedAt: Date
        let meetingStatus: MeetingStatus?
    }

    enum CompletionError: LocalizedError {
        case recordingSessionMissing

        var errorDescription: String? {
            L10n.recordingSessionNotActive
        }
    }

    static func finish(_ request: Request, in db: Database) throws -> RecordingSessionRecord {
        try db.execute(
            sql: """
            UPDATE recording_sessions
            SET endedAt = ?, duration = ?, updatedAt = ?
            WHERE id = ?
            """,
            arguments: [
                request.endedAt,
                request.duration,
                request.updatedAt,
                request.recordingSessionId,
            ]
        )

        let totalDuration = try Double.fetchOne(
            db,
            sql: "SELECT COALESCE(SUM(duration), 0) FROM recording_sessions WHERE meetingId = ?",
            arguments: [request.meetingId]
        ) ?? request.duration
        if var meeting = try MeetingRecord.fetchOne(db, key: request.meetingId) {
            if let meetingStatus = request.meetingStatus {
                meeting.status = meetingStatus
            }
            meeting.duration = totalDuration
            meeting.updatedAt = request.updatedAt
            try meeting.update(db)
        }

        guard let session = try RecordingSessionRecord.fetchOne(db, key: request.recordingSessionId) else {
            throw CompletionError.recordingSessionMissing
        }
        return session
    }
}
