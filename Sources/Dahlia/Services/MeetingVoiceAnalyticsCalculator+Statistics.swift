import Foundation

extension MeetingVoiceAnalyticsCalculator {
    static func loudnessSessionGroups(
        from segments: [MeasuredSegment]
    ) -> [SessionKey: [MeasuredSegment]] {
        Dictionary(grouping: segments.compactMap { segment -> (SessionKey, MeasuredSegment)? in
            guard let sessionId = segment.sessionId,
                  let loudness = segment.audioFeatures.activeRmsDecibels,
                  loudness.isFinite else { return nil }
            return (SessionKey(source: segment.source, sessionId: sessionId), segment)
        }, by: \.0).mapValues { $0.map(\.1) }
    }

    static func loudnessBaselines(
        for sessionGroups: [SessionKey: [MeasuredSegment]],
        configuration: Configuration
    ) -> [SessionKey: Baseline] {
        sessionGroups.compactMapValues { group in
            guard group.count >= configuration.minimumSessionSampleCount else { return nil }
            return baseline(
                values: group.compactMap(\.audioFeatures.activeRmsDecibels),
                floor: configuration.loudnessMADFloor
            )
        }
    }

    static func pitchBaselines(
        for pitchSegments: [RecordingAudioSource: [MeasuredSegment]],
        configuration: Configuration
    ) -> [RecordingAudioSource: Baseline] {
        pitchSegments.compactMapValues { group in
            guard group.count >= configuration.minimumPitchSampleCount else { return nil }
            return baseline(
                values: group.compactMap { segment in
                    segment.audioFeatures.medianPitchHertz.map(semitone)
                },
                floor: configuration.pitchMADFloorSemitones
            )
        }
    }

    static func bucketedSourceSamples(
        sources: [RecordingAudioSource],
        timelineDuration: TimeInterval,
        bucketDuration: TimeInterval,
        maximumSamplesPerSource: Int,
        value: (RecordingAudioSource, TimeInterval, TimeInterval) -> Double?
    ) -> [MeetingVoiceAnalytics.SourceSample] {
        guard timelineDuration.isFinite,
              timelineDuration > 0,
              bucketDuration.isFinite,
              bucketDuration > 0 else { return [] }
        let effectiveBucketDuration = resolvedBucketDuration(
            timelineDuration: timelineDuration,
            preferredBucketDuration: bucketDuration,
            maximumSampleCount: maximumSamplesPerSource
        )
        let bucketCount = min(maximumSamplesPerSource, Int(ceil(timelineDuration / effectiveBucketDuration)))
        return sources.flatMap { source in
            var seriesIndex = -1
            var previousHadValue = false
            return (0 ..< bucketCount).compactMap { index -> MeetingVoiceAnalytics.SourceSample? in
                let start = Double(index) * effectiveBucketDuration
                let end = min(start + effectiveBucketDuration, timelineDuration)
                guard let sampleValue = value(source, start, end) else {
                    previousHadValue = false
                    return nil
                }
                if !previousHadValue { seriesIndex += 1 }
                previousHadValue = true
                return MeetingVoiceAnalytics.SourceSample(
                    source: source,
                    start: start,
                    end: end,
                    value: sampleValue,
                    seriesIndex: seriesIndex
                )
            }
        }
    }

    static func weightedAverage(
        _ values: [(start: TimeInterval, end: TimeInterval, value: Double)],
        bucketStart: TimeInterval,
        bucketEnd: TimeInterval
    ) -> (value: Double, weight: Double)? {
        var weightedSum = 0.0
        var totalWeight = 0.0
        for item in values {
            let weight = max(0, min(item.end, bucketEnd) - max(item.start, bucketStart))
            guard weight > 0 else { continue }
            weightedSum += item.value * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }
        return (weightedSum / totalWeight, totalWeight)
    }

    static func resolvedBucketDuration(
        timelineDuration: TimeInterval,
        preferredBucketDuration: TimeInterval,
        maximumSampleCount: Int
    ) -> TimeInterval {
        guard maximumSampleCount > 0 else { return timelineDuration }
        let desiredDuration = timelineDuration / Double(maximumSampleCount)
        return max(
            preferredBucketDuration,
            ceil(desiredDuration / preferredBucketDuration) * preferredBucketDuration
        )
    }

    static func weightedLinearRegressionSlope(_ samples: [WeightedSample]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let totalWeight = samples.map(\.weight).reduce(0, +)
        guard totalWeight > 0 else { return nil }
        let meanX = samples.reduce(0) { $0 + $1.midpoint * $1.weight } / totalWeight
        let meanY = samples.reduce(0) { $0 + $1.value * $1.weight } / totalWeight
        let numerator = samples.reduce(0) {
            $0 + $1.weight * ($1.midpoint - meanX) * ($1.value - meanY)
        }
        let denominator = samples.reduce(0) {
            $0 + $1.weight * pow($1.midpoint - meanX, 2)
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    static func baseline(values: [Double], floor: Double) -> Baseline? {
        guard let median = median(values) else { return nil }
        let mad = Self.median(values.map { abs($0 - median) }) ?? 0
        return Baseline(median: median, scale: max(mad, floor))
    }

    static func robustZ(
        _ value: Double,
        baseline: Baseline,
        configuration: Configuration
    ) -> Double {
        configuration.robustZScale * (value - baseline.median) / baseline.scale
    }

    static func semitone(_ hertz: Double) -> Double {
        12 * log2(hertz / 100)
    }

    static func level(
        _ value: Double,
        lowThreshold: Double,
        highThreshold: Double
    ) -> MeetingVoiceAnalytics.ExpressionLevel {
        if value < lowThreshold { return .low }
        if value > highThreshold { return .high }
        return .standard
    }

    static func median(_ values: [Double]) -> Double? {
        quantile(0.5, values: values)
    }

    static func interquartileRange(_ values: [Double]) -> Double? {
        guard let lower = quantile(0.25, values: values),
              let upper = quantile(0.75, values: values) else { return nil }
        return upper - lower
    }

    static func quantile(_ probability: Double, values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = probability * Double(sorted.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = Int(ceil(position))
        guard lowerIndex != upperIndex else { return sorted[lowerIndex] }
        let fraction = position - Double(lowerIndex)
        return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
    }

    static func unionDuration(_ intervals: [(TimeInterval, TimeInterval)]) -> TimeInterval {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        guard var current = sorted.first else { return 0 }
        var duration = 0.0
        for interval in sorted.dropFirst() {
            if interval.0 <= current.1 {
                current.1 = max(current.1, interval.1)
            } else {
                duration += current.1 - current.0
                current = interval
            }
        }
        return duration + current.1 - current.0
    }

    static func chronological(_ lhs: MeasuredSegment, _ rhs: MeasuredSegment) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.end < rhs.end
    }

    static func chronological(_ lhs: ScoredSegment, _ rhs: ScoredSegment) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.end < rhs.end
    }
}
