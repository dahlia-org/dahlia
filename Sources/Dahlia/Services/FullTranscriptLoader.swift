import Foundation
import GRDB

struct FullTranscriptSummaryInput {
    let segments: [TranscriptSegment]
    let text: String
}

/// Bounded UI projection を経由せず、全文利用機能へ SQLite の全セグメントを供給する。
enum FullTranscriptLoader {
    nonisolated static func summaryInput(
        meetingId: UUID,
        dbQueue: DatabaseQueue,
        recordingSessions: [RecordingSessionTimeline],
        timeBase: Date
    ) throws -> FullTranscriptSummaryInput {
        let segments = try loadSegments(meetingId: meetingId, dbQueue: dbQueue)
        return FullTranscriptSummaryInput(
            segments: segments,
            text: TranscriptTextFormatter.summaryText(
                segments: segments,
                recordingSessions: recordingSessions,
                timeBase: timeBase
            )
        )
    }

    nonisolated static func plainText(
        meetingId: UUID,
        dbQueue: DatabaseQueue,
        recordingSessions: [RecordingSessionTimeline],
        timeBase: Date
    ) throws -> String {
        let segments = try loadSegments(meetingId: meetingId, dbQueue: dbQueue)
        return TranscriptTextFormatter.plainText(
            segments: segments,
            recordingSessions: recordingSessions,
            timeBase: timeBase
        )
    }

    private nonisolated static func loadSegments(
        meetingId: UUID,
        dbQueue: DatabaseQueue
    ) throws -> [TranscriptSegment] {
        try MeetingRepository(dbQueue: dbQueue)
            .fetchSegments(forMeetingId: meetingId)
            .map(TranscriptSegment.init(from:))
    }
}
