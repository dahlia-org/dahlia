import Foundation
import GRDB

/// 録音停止時の最終 transaction を MainActor から隔離して実行する。
enum MeetingPersistenceFinalizer {
    struct Request {
        let recordingSessionId: UUID
        let meetingId: UUID
        let endedAt: Date
        let duration: TimeInterval
        let persistsStreamingSegments: Bool
    }

    static func finish(
        _ request: Request,
        dbQueue: DatabaseQueue
    ) async throws -> RecordingSessionRecord {
        try await dbQueue.write { db in
            try RecordingSessionCompletionWriter.finish(
                RecordingSessionCompletionWriter.Request(
                    recordingSessionId: request.recordingSessionId,
                    meetingId: request.meetingId,
                    endedAt: request.endedAt,
                    duration: request.duration,
                    updatedAt: request.endedAt,
                    meetingStatus: request.persistsStreamingSegments ? .ready : nil
                ),
                in: db
            )
        }
    }
}
