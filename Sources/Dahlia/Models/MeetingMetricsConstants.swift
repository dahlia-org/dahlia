import Foundation

enum MeetingMetricsConstants {
    static let metricsVersion = 1
    static let turnGapSeconds = 2.0
    static let minimumOverlapEpisodeSeconds = 0.5
    static let minimumSourceSpeakingSeconds = 60.0
    static let minimumConversationTalkSeconds = 180.0
    static let minimumTotalTurnCount = 6
    static let minimumLabelledSegmentRatio = 0.8
    static let maximumUnknownCharacterRatio = 0.2
    static let minimumValidCharacterRatio = 0.7
    static let provisionalFastCharactersPerMinute = 420.0
    static let minimumCJKCharacterRatio = 0.7
    static let highMicShareThreshold = 0.65
    static let highOverlapShareThreshold = 0.10
    static let micPaceMinimumSpeakingSeconds = 120.0
    static let micPaceMinimumTurnCount = 3
    static let cancellationCheckSegmentStride = 500
}
