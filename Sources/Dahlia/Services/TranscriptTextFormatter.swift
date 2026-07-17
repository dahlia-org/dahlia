import Foundation

enum TranscriptTextFormatter {
    static func plainText(
        segments: [TranscriptSegment],
        recordingSessions: [RecordingSessionTimeline],
        timeBase: Date
    ) -> String {
        segments.map { segment in
            let time = Formatters.elapsedHHmmss(
                at: segment.startTime,
                sessionId: segment.sessionId,
                sessions: recordingSessions,
                fallbackTimeBase: timeBase
            )
            let speaker = segment.speakerLabel.map { "[\($0)] " } ?? ""
            return "[\(time)] \(speaker)\(segment.displayText)"
        }.joined(separator: "\n")
    }

    static func summaryText(
        segments: [TranscriptSegment],
        recordingSessions: [RecordingSessionTimeline],
        timeBase: Date
    ) -> String {
        segments.map { segment in
            let time = Formatters.elapsedHHmmss(
                at: segment.startTime,
                sessionId: segment.sessionId,
                sessions: recordingSessions,
                fallbackTimeBase: timeBase
            )
            return "<time>\(time)</time> \(segment.displayText)"
        }.joined(separator: "\n")
    }
}
