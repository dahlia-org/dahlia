import Foundation

struct MeetingSourceMetricsRow: Sendable, Equatable {
    let meetingId: UUID
    let source: MetricsSource
    let speakingSeconds: Double
    let characterCount: Int
    let cjkCharacterCount: Int
    let turnCount: Int
    let charactersPerMinute: Double?

    var cjkRatio: Double {
        guard characterCount > 0 else { return 0 }
        return Double(cjkCharacterCount) / Double(characterCount)
    }
}

struct MeetingMetricsResult: Sendable, Equatable {
    let meetingId: UUID
    let metricsVersion: Int
    let transcriptRevision: Int64
    let conversationTalkSeconds: Double
    let overlapSeconds: Double?
    let talkBalance: Double?
    let confirmedSegmentCount: Int
    let validSegmentCount: Int
    let invalidDurationSegmentCount: Int
    let unknownSourceSegmentCount: Int
    let totalCharacterCount: Int
    let validCharacterCount: Int
    let unknownSourceCharacterCount: Int
    let sourceRows: [MeetingSourceMetricsRow]
    let isPartialAnalysis: Bool

    func source(_ source: MetricsSource) -> MeetingSourceMetricsRow? {
        sourceRows.first { $0.source == source }
    }

    var labelledSegmentRatio: Double {
        guard confirmedSegmentCount > 0 else { return 0 }
        return Double(confirmedSegmentCount - unknownSourceSegmentCount) / Double(confirmedSegmentCount)
    }

    var unknownCharacterRatio: Double {
        guard totalCharacterCount > 0 else { return 0 }
        return Double(unknownSourceCharacterCount) / Double(totalCharacterCount)
    }

    var validCharacterRatio: Double {
        guard totalCharacterCount > 0 else { return 0 }
        return Double(validCharacterCount) / Double(totalCharacterCount)
    }

    var sourceComparisonGatePassed: Bool {
        guard let microphone = source(.microphone), let system = source(.system) else { return false }
        return microphone.speakingSeconds >= MeetingMetricsConstants.minimumSourceSpeakingSeconds
            && system.speakingSeconds >= MeetingMetricsConstants.minimumSourceSpeakingSeconds
    }
}
