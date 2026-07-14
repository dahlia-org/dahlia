import Foundation
import GRDB

/// 録音停止時の最終 transaction を MainActor から隔離して実行する。
enum MeetingPersistenceFinalizer {
    struct Request {
        let finalSegmentRecords: [TranscriptSegmentRecord]
        let recordingSessionId: UUID
        let meetingId: UUID
        let endedAt: Date
        let duration: TimeInterval
        let persistsStreamingSegments: Bool
    }

    private enum FinalizationError: LocalizedError {
        case recordingSessionMissing

        var errorDescription: String? {
            L10n.recordingSessionNotActive
        }
    }

    static func finish(
        _ request: Request,
        dbQueue: DatabaseQueue
    ) async throws -> RecordingSessionRecord {
        try await dbQueue.write { db in
            try persistFinalSegments(request.finalSegmentRecords, in: db)
            try updateRecordingSession(request, in: db)
            try updateMeeting(request, in: db)

            guard let persistedSession = try RecordingSessionRecord.fetchOne(
                db,
                key: request.recordingSessionId
            ) else {
                throw FinalizationError.recordingSessionMissing
            }
            return persistedSession
        }
    }

    private static func persistFinalSegments(
        _ records: [TranscriptSegmentRecord],
        in db: Database
    ) throws {
        for record in records {
            if let existing = try TranscriptSegmentRecord.fetchOne(db, key: record.id) {
                guard existing.translatedText != record.translatedText else { continue }
                try TranscriptSegmentRecord.updateTranslatedText(
                    record.translatedText,
                    id: record.id,
                    in: db
                )
            } else {
                try record.insert(db)
            }
        }
    }

    private static func updateRecordingSession(
        _ request: Request,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE recording_sessions
            SET endedAt = ?, duration = ?, updatedAt = ?
            WHERE id = ?
            """,
            arguments: [
                request.endedAt,
                request.duration,
                request.endedAt,
                request.recordingSessionId,
            ]
        )
    }

    private static func updateMeeting(
        _ request: Request,
        in db: Database
    ) throws {
        let totalDuration = try Double.fetchOne(
            db,
            sql: "SELECT COALESCE(SUM(duration), 0) FROM recording_sessions WHERE meetingId = ?",
            arguments: [request.meetingId]
        ) ?? request.duration

        guard var record = try MeetingRecord.fetchOne(db, key: request.meetingId) else { return }
        if request.persistsStreamingSegments {
            record.status = .ready
        }
        record.duration = totalDuration
        record.updatedAt = request.endedAt
        try record.update(db)
    }
}
