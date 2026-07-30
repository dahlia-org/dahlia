import Foundation

struct MeetingConversationMetrics: Equatable, Sendable {
    struct PaceSample: Equatable, Identifiable, Sendable {
        let source: RecordingAudioSource
        let start: TimeInterval
        let end: TimeInterval
        let charactersPerMinute: Double
        let seriesIndex: Int

        var id: String {
            "\(source.rawValue):\(start.bitPattern):\(end.bitPattern)"
        }

        var seriesID: String {
            "\(source.rawValue):\(seriesIndex)"
        }

        var midpoint: TimeInterval {
            start + (end - start) / 2
        }
    }

    struct TimelineInterval: Equatable, Identifiable, Sendable {
        let source: RecordingAudioSource
        let start: TimeInterval
        let end: TimeInterval

        var id: String {
            "\(source.rawValue):\(start.bitPattern):\(end.bitPattern)"
        }
    }

    struct OverlapInterval: Equatable, Identifiable, Sendable {
        let start: TimeInterval
        let end: TimeInterval

        var id: String {
            "\(start.bitPattern):\(end.bitPattern)"
        }
    }

    struct SourceMetrics: Equatable, Identifiable, Sendable {
        let source: RecordingAudioSource
        let speechDuration: TimeInterval
        let normalizedCharacterCount: Int
        let segmentCount: Int
        let unmeasurableSegmentCount: Int

        var id: RecordingAudioSource { source }

        var charactersPerMinute: Double? {
            guard speechDuration > 0 else { return nil }
            return Double(normalizedCharacterCount) / speechDuration * 60
        }
    }

    nonisolated static let calculationVersion = 3

    let inputFingerprint: String
    let recordingDuration: TimeInterval
    let unionSpeechDuration: TimeInterval
    let overlapDuration: TimeInterval
    let usesLegacyTimelineFallback: Bool
    let computedAt: Date
    let sources: [SourceMetrics]
    let speechMergeGap: TimeInterval
    let paceSamples: [PaceSample]
    let paceBucketDuration: TimeInterval
    let timelineIntervals: [TimelineInterval]
    let overlapIntervals: [OverlapInterval]
    let overlapCount: Int
    let isTimelineCondensed: Bool

    var totalSourceSpeechDuration: TimeInterval {
        sources.reduce(0) { $0 + $1.speechDuration }
    }

    var conversationOccupancyRatio: Double? {
        ratio(unionSpeechDuration, to: recordingDuration)
    }

    var overlapRatio: Double? {
        ratio(overlapDuration, to: unionSpeechDuration)
    }

    var timelineDuration: TimeInterval {
        max(recordingDuration, timelineIntervals.map(\.end).max() ?? 0)
    }

    var hasSegments: Bool {
        sources.contains { $0.segmentCount > 0 }
    }

    var hasUnmeasurableSegments: Bool {
        sources.contains { $0.unmeasurableSegmentCount > 0 }
    }

    func source(_ source: RecordingAudioSource) -> SourceMetrics {
        sources.first(where: { $0.source == source })
            ?? SourceMetrics(
                source: source,
                speechDuration: 0,
                normalizedCharacterCount: 0,
                segmentCount: 0,
                unmeasurableSegmentCount: 0
            )
    }

    func speechShare(for source: RecordingAudioSource) -> Double? {
        ratio(self.source(source).speechDuration, to: totalSourceSpeechDuration)
    }

    private func ratio(_ numerator: Double, to denominator: Double) -> Double? {
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }
}
