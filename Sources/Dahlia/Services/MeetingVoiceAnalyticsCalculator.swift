import Foundation

enum MeetingVoiceAnalyticsCalculator {
    struct MeasuredSegment: Equatable, Sendable {
        let source: RecordingAudioSource
        let sessionId: UUID?
        let start: TimeInterval
        let end: TimeInterval
        let audioFeatures: TranscriptAudioFeatures
    }

    struct Configuration: Equatable, Sendable {
        static let `default` = Self()

        var minimumSourceSampleCount = 10
        var minimumSessionSampleCount = 5
        var minimumPitchSampleCount = 10
        var loudnessMADFloor = 1.0
        var pitchMADFloor = 5.0
        var robustZScale = 0.67448975
        var loudnessWeight = 0.6
        var pitchWeight = 0.4
        var smoothingWindowSize = 3
        var hotspotThreshold = 1.5
        var hotspotMergeGap: TimeInterval = 15
        var minimumHotspotCoveredDuration: TimeInterval = 10
        var maximumHotspotCount = 8
        var maximumSamplesPerSource = 60
        var chartScoreLimit = 3.0
        var lowPitchVariationThreshold = 1.5
        var highPitchVariationThreshold = 3.0
        var lowLoudnessVariationThreshold = 2.0
        var highLoudnessVariationThreshold = 5.0
        var minimumEntrainmentBucketCount = 4
        var decliningSlopePerMinute = -0.2
    }

    struct SessionKey: Hashable {
        let source: RecordingAudioSource
        let sessionId: UUID
    }

    struct Baseline {
        let median: Double
        let scale: Double
    }

    struct ScoredSegment {
        let source: RecordingAudioSource
        let sessionId: UUID
        let start: TimeInterval
        let end: TimeInterval
        let score: Double
        let loudnessZ: Double
        let pitchZ: Double?
    }

    private struct RelativeLoudnessSegment {
        let source: RecordingAudioSource
        let start: TimeInterval
        let end: TimeInterval
        let relativeDecibels: Double
    }

    struct WeightedSample {
        let midpoint: TimeInterval
        let value: Double
        let weight: Double
    }

    private static let sources: [RecordingAudioSource] = [.microphone, .system]

    static func calculate(
        segments: [MeasuredSegment],
        timelineDuration: TimeInterval,
        bucketDuration: TimeInterval,
        configuration: Configuration = .default
    ) -> MeetingVoiceAnalytics {
        let validSegments = segments.filter(isValid)
        let allSessionGroups = loudnessSessionGroups(from: validSegments)
        let statuses = sourceStatuses(
            segments: validSegments,
            sessionGroups: allSessionGroups,
            configuration: configuration
        )
        let availableSources = Set(statuses.compactMap { status in
            status.availability == .available ? status.source : nil
        })
        let sessionGroups = allSessionGroups.filter { availableSources.contains($0.key.source) }
        let loudnessBaselines = loudnessBaselines(for: sessionGroups, configuration: configuration)
        let pitchSegments = Dictionary(
            grouping: validSegments.filter { availableSources.contains($0.source) && hasUsablePitch($0) },
            by: \.source
        )
        let pitchBaselines = pitchBaselines(for: pitchSegments, configuration: configuration)
        let smoothedScores = smoothedExcitementScores(
            sessionGroups: sessionGroups,
            loudnessBaselines: loudnessBaselines,
            pitchBaselines: pitchBaselines,
            configuration: configuration
        )
        let excitement = MeetingVoiceAnalytics.Excitement(
            samples: bucketedScoreSamples(
                smoothedScores,
                timelineDuration: timelineDuration,
                bucketDuration: bucketDuration,
                configuration: configuration
            ),
            hotspots: hotspots(from: smoothedScores, configuration: configuration),
            sourcesUsingPitch: Set(pitchBaselines.keys)
        )
        let relativeLoudness = relativeLoudnessSegments(
            sessionGroups: sessionGroups,
            baselines: loudnessBaselines
        )
        return MeetingVoiceAnalytics(
            excitement: excitement,
            expressions: expressions(
                sessionGroups: sessionGroups,
                pitchSegments: pitchSegments,
                configuration: configuration
            ),
            pitchEntrainment: pitchEntrainment(
                pitchSegments: pitchSegments,
                timelineDuration: timelineDuration,
                bucketDuration: bucketDuration,
                configuration: configuration
            ),
            energyTrend: energyTrend(
                segments: relativeLoudness,
                timelineDuration: timelineDuration,
                bucketDuration: bucketDuration,
                configuration: configuration
            ),
            sourceStatuses: statuses
        )
    }

    private static func isValid(_ segment: MeasuredSegment) -> Bool {
        segment.audioFeatures.version == TranscriptAudioFeatures.currentVersion
            && segment.start.isFinite
            && segment.end.isFinite
            && segment.end > segment.start
    }

    private static func hasUsablePitch(_ segment: MeasuredSegment) -> Bool {
        guard let pitch = segment.audioFeatures.medianPitchHertz,
              let spread = segment.audioFeatures.pitchSpreadHertz else { return false }
        return pitch.isFinite && pitch > 0 && spread.isFinite && spread >= 0
    }

    private static func sourceStatuses(
        segments: [MeasuredSegment],
        sessionGroups: [SessionKey: [MeasuredSegment]],
        configuration: Configuration
    ) -> [MeetingVoiceAnalytics.SourceStatus] {
        sources.map { source in
            let measuredCount = segments.count { segment in
                segment.source == source
                    && segment.audioFeatures.activeRmsDecibels?.isFinite == true
            }
            let analyzableCount = sessionGroups.reduce(0) { count, entry in
                guard entry.key.source == source,
                      entry.value.count >= configuration.minimumSessionSampleCount else { return count }
                return count + entry.value.count
            }
            let availability: MeetingVoiceAnalytics.Availability = if measuredCount == 0 {
                .unavailable
            } else if analyzableCount < configuration.minimumSourceSampleCount {
                .insufficientSamples
            } else {
                .available
            }
            return MeetingVoiceAnalytics.SourceStatus(source: source, availability: availability)
        }
    }

    private static func smoothedExcitementScores(
        sessionGroups: [SessionKey: [MeasuredSegment]],
        loudnessBaselines: [SessionKey: Baseline],
        pitchBaselines: [RecordingAudioSource: Baseline],
        configuration: Configuration
    ) -> [ScoredSegment] {
        sessionGroups.flatMap { key, group -> [ScoredSegment] in
            guard let loudnessBaseline = loudnessBaselines[key] else { return [] }
            let pitchBaseline = pitchBaselines[key.source]
            let raw = group.sorted(by: chronological).compactMap { segment -> ScoredSegment? in
                guard let loudness = segment.audioFeatures.activeRmsDecibels else { return nil }
                let loudnessZ = robustZ(loudness, baseline: loudnessBaseline, configuration: configuration)
                let pitchZ: Double? = if hasUsablePitch(segment),
                                         let pitch = segment.audioFeatures.medianPitchHertz,
                                         let pitchBaseline {
                    robustZ(pitch, baseline: pitchBaseline, configuration: configuration)
                } else {
                    nil
                }
                let score = if let pitchZ {
                    configuration.loudnessWeight * loudnessZ + configuration.pitchWeight * pitchZ
                } else {
                    loudnessZ
                }
                return ScoredSegment(
                    source: key.source,
                    sessionId: key.sessionId,
                    start: segment.start,
                    end: segment.end,
                    score: score,
                    loudnessZ: loudnessZ,
                    pitchZ: pitchZ
                )
            }
            let radius = max(0, configuration.smoothingWindowSize / 2)
            return raw.indices.map { index in
                let lower = max(raw.startIndex, index - radius)
                let upper = min(raw.index(before: raw.endIndex), index + radius)
                let window = raw[lower ... upper]
                let average = window.map(\.score).reduce(0, +) / Double(window.count)
                let segment = raw[index]
                return ScoredSegment(
                    source: segment.source,
                    sessionId: segment.sessionId,
                    start: segment.start,
                    end: segment.end,
                    score: average,
                    loudnessZ: segment.loudnessZ,
                    pitchZ: segment.pitchZ
                )
            }
        }
        .sorted(by: chronological)
    }

    private static func bucketedScoreSamples(
        _ segments: [ScoredSegment],
        timelineDuration: TimeInterval,
        bucketDuration: TimeInterval,
        configuration: Configuration
    ) -> [MeetingVoiceAnalytics.SourceSample] {
        let valuesBySource = Dictionary(grouping: segments, by: \.source).mapValues { sourceSegments in
            sourceSegments.map { ($0.start, $0.end, $0.score) }
        }
        return bucketedSourceSamples(
            sources: sources,
            timelineDuration: timelineDuration,
            bucketDuration: bucketDuration,
            maximumSamplesPerSource: configuration.maximumSamplesPerSource
        ) { source, start, end in
            weightedAverage(
                valuesBySource[source] ?? [],
                bucketStart: start,
                bucketEnd: end
            ).map { min(max($0.value, -configuration.chartScoreLimit), configuration.chartScoreLimit) }
        }
    }

    private static func hotspots(
        from segments: [ScoredSegment],
        configuration: Configuration
    ) -> [MeetingVoiceAnalytics.Hotspot] {
        let groups = Dictionary(grouping: segments.filter { $0.score >= configuration.hotspotThreshold }) {
            SessionKey(source: $0.source, sessionId: $0.sessionId)
        }
        return groups.flatMap { _, group -> [MeetingVoiceAnalytics.Hotspot] in
            let sorted = group.sorted(by: chronological)
            guard let first = sorted.first else { return [] }
            var members = [first]
            var mergedEnd = first.end
            var results: [MeetingVoiceAnalytics.Hotspot] = []
            for segment in sorted.dropFirst() {
                if segment.start <= mergedEnd + configuration.hotspotMergeGap {
                    members.append(segment)
                    mergedEnd = max(mergedEnd, segment.end)
                } else {
                    if let hotspot = hotspot(from: members, configuration: configuration) {
                        results.append(hotspot)
                    }
                    members = [segment]
                    mergedEnd = segment.end
                }
            }
            if let hotspot = hotspot(from: members, configuration: configuration) {
                results.append(hotspot)
            }
            return results
        }
        .sorted { $0.start < $1.start }
        .prefix(configuration.maximumHotspotCount)
        .map(\.self)
    }

    private static func hotspot(
        from segments: [ScoredSegment],
        configuration: Configuration
    ) -> MeetingVoiceAnalytics.Hotspot? {
        guard let first = segments.first else { return nil }
        let end = segments.dropFirst().reduce(first.end) { max($0, $1.end) }
        let coveredDuration = unionDuration(segments.map { ($0.start, $0.end) })
        guard coveredDuration >= configuration.minimumHotspotCoveredDuration,
              let peak = segments.max(by: { $0.score < $1.score }) else { return nil }
        let driver: MeetingVoiceAnalytics.HotspotDriver = if let pitchZ = peak.pitchZ,
                                                             peak.loudnessZ >= configuration.hotspotThreshold,
                                                             pitchZ >= configuration.hotspotThreshold {
            .both
        } else if let pitchZ = peak.pitchZ,
                  configuration.pitchWeight * pitchZ
                  > configuration.loudnessWeight * peak.loudnessZ {
            .pitch
        } else {
            .loudness
        }
        return MeetingVoiceAnalytics.Hotspot(
            source: first.source,
            start: first.start,
            end: end,
            coveredDuration: coveredDuration,
            peakScore: peak.score,
            driver: driver
        )
    }

    private static func relativeLoudnessSegments(
        sessionGroups: [SessionKey: [MeasuredSegment]],
        baselines: [SessionKey: Baseline]
    ) -> [RelativeLoudnessSegment] {
        sessionGroups.flatMap { key, group -> [RelativeLoudnessSegment] in
            guard let baseline = baselines[key] else { return [] }
            return group.compactMap { segment in
                guard let loudness = segment.audioFeatures.activeRmsDecibels else { return nil }
                return RelativeLoudnessSegment(
                    source: key.source,
                    start: segment.start,
                    end: segment.end,
                    relativeDecibels: loudness - baseline.median
                )
            }
        }
    }

    private static func expressions(
        sessionGroups: [SessionKey: [MeasuredSegment]],
        pitchSegments: [RecordingAudioSource: [MeasuredSegment]],
        configuration: Configuration
    ) -> [MeetingVoiceAnalytics.SourceExpression] {
        sources.map { source in
            let sourcePitchSegments = pitchSegments[source] ?? []
            let pitchVariation: Double? = if sourcePitchSegments.count >= configuration.minimumPitchSampleCount {
                pitchVariation(sourcePitchSegments)
            } else {
                nil
            }
            let sessionIQRs = sessionGroups.compactMap { key, group -> Double? in
                guard key.source == source,
                      group.count >= configuration.minimumSessionSampleCount else { return nil }
                return interquartileRange(group.compactMap(\.audioFeatures.activeRmsDecibels))
            }
            let loudnessVariation = median(sessionIQRs)
            return MeetingVoiceAnalytics.SourceExpression(
                source: source,
                pitchVariationSemitones: pitchVariation,
                pitchLevel: pitchVariation.map {
                    level(
                        $0,
                        lowThreshold: configuration.lowPitchVariationThreshold,
                        highThreshold: configuration.highPitchVariationThreshold
                    )
                },
                loudnessVariationDecibels: loudnessVariation,
                loudnessLevel: loudnessVariation.map {
                    level(
                        $0,
                        lowThreshold: configuration.lowLoudnessVariationThreshold,
                        highThreshold: configuration.highLoudnessVariationThreshold
                    )
                }
            )
        }
    }

    private static func pitchVariation(_ segments: [MeasuredSegment]) -> Double? {
        let semitones = segments.compactMap { segment in
            segment.audioFeatures.medianPitchHertz.map(semitone)
        }
        let between = interquartileRange(semitones)
        let within = median(segments.compactMap { segment -> Double? in
            guard let pitch = segment.audioFeatures.medianPitchHertz,
                  let spread = segment.audioFeatures.pitchSpreadHertz,
                  pitch > 0,
                  pitch + spread > 0 else { return nil }
            return 12 * log2((pitch + spread) / pitch)
        })
        return [between, within].compactMap(\.self).max()
    }

    private static func pitchEntrainment(
        pitchSegments: [RecordingAudioSource: [MeasuredSegment]],
        timelineDuration: TimeInterval,
        bucketDuration: TimeInterval,
        configuration: Configuration
    ) -> MeetingVoiceAnalytics.PitchEntrainment? {
        guard sources.allSatisfy({ (pitchSegments[$0] ?? []).count >= configuration.minimumPitchSampleCount }),
              timelineDuration.isFinite,
              timelineDuration > 0,
              bucketDuration.isFinite,
              bucketDuration > 0 else { return nil }
        let effectiveBucketDuration = resolvedBucketDuration(
            timelineDuration: timelineDuration,
            preferredBucketDuration: bucketDuration,
            maximumSampleCount: configuration.maximumSamplesPerSource
        )
        let bucketCount = min(configuration.maximumSamplesPerSource, Int(ceil(timelineDuration / effectiveBucketDuration)))
        var seriesIndex = -1
        var previousHadValue = false
        let samples = (0 ..< bucketCount).compactMap { index -> MeetingVoiceAnalytics.PitchDistanceSample? in
            let start = Double(index) * effectiveBucketDuration
            let end = min(start + effectiveBucketDuration, timelineDuration)
            let medians = sources.compactMap { source -> Double? in
                let values = (pitchSegments[source] ?? []).compactMap { segment -> Double? in
                    let midpoint = segment.start + (segment.end - segment.start) / 2
                    guard midpoint >= start, midpoint < end else { return nil }
                    return segment.audioFeatures.medianPitchHertz.map(semitone)
                }
                return median(values)
            }
            guard medians.count == 2 else {
                previousHadValue = false
                return nil
            }
            if !previousHadValue { seriesIndex += 1 }
            previousHadValue = true
            return MeetingVoiceAnalytics.PitchDistanceSample(
                start: start,
                end: end,
                distanceSemitones: abs(medians[0] - medians[1]),
                seriesIndex: seriesIndex
            )
        }
        guard samples.count >= configuration.minimumEntrainmentBucketCount else { return nil }
        let thirdCount = max(1, samples.count / 3)
        let firstMean = samples.prefix(thirdCount).map(\.distanceSemitones).reduce(0, +) / Double(thirdCount)
        let lastMean = samples.suffix(thirdCount).map(\.distanceSemitones).reduce(0, +) / Double(thirdCount)
        return MeetingVoiceAnalytics.PitchEntrainment(
            distanceSamples: samples,
            firstThirdMeanDistance: firstMean,
            lastThirdMeanDistance: lastMean,
            isConverging: lastMean < firstMean
        )
    }

    private static func energyTrend(
        segments: [RelativeLoudnessSegment],
        timelineDuration: TimeInterval,
        bucketDuration: TimeInterval,
        configuration: Configuration
    ) -> MeetingVoiceAnalytics.EnergyTrend {
        var weightedSamples: [RecordingAudioSource: [WeightedSample]] = [:]
        let valuesBySource = Dictionary(grouping: segments, by: \.source).mapValues { sourceSegments in
            sourceSegments.map { ($0.start, $0.end, $0.relativeDecibels) }
        }
        let samples = bucketedSourceSamples(
            sources: sources,
            timelineDuration: timelineDuration,
            bucketDuration: bucketDuration,
            maximumSamplesPerSource: configuration.maximumSamplesPerSource
        ) { source, start, end in
            let average = weightedAverage(
                valuesBySource[source] ?? [],
                bucketStart: start,
                bucketEnd: end
            )
            if let average {
                weightedSamples[source, default: []].append(WeightedSample(
                    midpoint: start + (end - start) / 2,
                    value: average.value,
                    weight: average.weight
                ))
            }
            return average?.value
        }
        var slopes: [RecordingAudioSource: Double] = [:]
        for source in sources {
            if let slope = weightedLinearRegressionSlope(weightedSamples[source] ?? []) {
                slopes[source] = slope * 60
            }
        }
        return MeetingVoiceAnalytics.EnergyTrend(
            samples: samples,
            slopePerMinute: slopes,
            decliningSources: Set(slopes.compactMap { source, slope in
                slope <= configuration.decliningSlopePerMinute ? source : nil
            })
        )
    }

}
