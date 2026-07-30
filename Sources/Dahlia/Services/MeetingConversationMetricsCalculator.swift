import Foundation

enum MeetingConversationMetricsCalculator {
    static let defaultSpeechMergeGap: TimeInterval = 1.5
    static let maximumTimelineIntervalsPerLane = 512
    private static let sources: [RecordingAudioSource] = [.microphone, .system]

    private struct Interval: Equatable {
        let start: TimeInterval
        let end: TimeInterval

        var duration: TimeInterval { end - start }
    }

    private struct ValidSession {
        let startedAt: Date
        let duration: TimeInterval
        let offsetSeconds: TimeInterval
    }

    private struct SourceAccumulator {
        var intervals: [Interval] = []
        var normalizedCharacterCount = 0
        var segmentCount = 0
        var unmeasurableSegmentCount = 0
    }

    private struct Analysis {
        let accumulators: [RecordingAudioSource: SourceAccumulator]
        let mergedBySource: [RecordingAudioSource: [Interval]]
        let allIntervals: [Interval]
        let overlapIntervals: [Interval]
        let usesLegacyTimelineFallback: Bool
    }

    struct TimelineProjection {
        let intervals: [MeetingConversationMetrics.TimelineInterval]
        let overlaps: [MeetingConversationMetrics.OverlapInterval]
        let overlapCount: Int
        let isCondensed: Bool
    }

    private struct DisplayIntervals {
        let intervals: [Interval]
        let isCondensed: Bool
    }

    static func calculate(
        input: MeetingConversationMetricsInput,
        fingerprint: String,
        computedAt: Date = .now,
        speechMergeGap: TimeInterval = defaultSpeechMergeGap
    ) -> MeetingConversationMetrics {
        let mergeGap = normalizedSpeechMergeGap(speechMergeGap)
        let analysis = analyze(input: input, mergeGap: mergeGap)
        let recordingDuration = recordingDuration(for: input, analysis: analysis)
        let timeline = timelineProjection(
            from: analysis,
            timelineDuration: max(recordingDuration, analysis.allIntervals.last?.end ?? 0)
        )

        return MeetingConversationMetrics(
            inputFingerprint: fingerprint,
            recordingDuration: recordingDuration,
            unionSpeechDuration: duration(of: analysis.allIntervals),
            overlapDuration: duration(of: analysis.overlapIntervals),
            usesLegacyTimelineFallback: analysis.usesLegacyTimelineFallback,
            computedAt: computedAt,
            sources: sourceMetrics(
                accumulators: analysis.accumulators,
                mergedBySource: analysis.mergedBySource
            ),
            speechMergeGap: mergeGap,
            timelineIntervals: timeline.intervals,
            overlapIntervals: timeline.overlaps,
            overlapCount: timeline.overlapCount,
            isTimelineCondensed: timeline.isCondensed
        )
    }

    static func timelineProjection(
        input: MeetingConversationMetricsInput,
        speechMergeGap: TimeInterval = defaultSpeechMergeGap
    ) -> TimelineProjection {
        let mergeGap = normalizedSpeechMergeGap(speechMergeGap)
        let analysis = analyze(input: input, mergeGap: mergeGap)
        let recordingDuration = recordingDuration(for: input, analysis: analysis)
        return timelineProjection(
            from: analysis,
            timelineDuration: max(recordingDuration, analysis.allIntervals.last?.end ?? 0)
        )
    }

    static func normalizedCharacterCount(_ text: String) -> Int {
        text.lazy.filter { !$0.isWhitespace }.count
    }

    private static func analyze(
        input: MeetingConversationMetricsInput,
        mergeGap: TimeInterval
    ) -> Analysis {
        let validSessions = validSessions(from: input.sessions)
        let knownTimelineEnd = validSessions.values.reduce(0) { current, session in
            max(current, session.offsetSeconds + session.duration)
        }
        let legacySegments = input.segments.filter { segment in
            guard let sessionId = segment.sessionId else { return true }
            return validSessions[sessionId] == nil
        }
        let legacyOrigin = legacySegments.map(\.startTime).min()
        var accumulators = Dictionary(
            uniqueKeysWithValues: sources.map {
                ($0, SourceAccumulator())
            }
        )

        for segment in input.segments {
            guard let source = RecordingAudioSource(speakerLabel: segment.speakerLabel) else { continue }
            var accumulator = accumulators[source, default: SourceAccumulator()]
            accumulator.segmentCount += 1
            accumulator.normalizedCharacterCount += normalizedCharacterCount(segment.text)

            if let interval = interval(
                for: segment,
                validSessions: validSessions,
                legacyOrigin: legacyOrigin,
                legacyBaseOffset: knownTimelineEnd
            ) {
                accumulator.intervals.append(interval)
            } else {
                accumulator.unmeasurableSegmentCount += 1
            }
            accumulators[source] = accumulator
        }

        let mergedBySource = Dictionary(
            uniqueKeysWithValues: sources.map { source in
                (
                    source,
                    merged(
                        accumulators[source, default: SourceAccumulator()].intervals,
                        mergeGap: mergeGap
                    )
                )
            }
        )
        let microphoneIntervals = mergedBySource[.microphone] ?? []
        let systemIntervals = mergedBySource[.system] ?? []
        let allIntervals = merged(microphoneIntervals + systemIntervals)
        return Analysis(
            accumulators: accumulators,
            mergedBySource: mergedBySource,
            allIntervals: allIntervals,
            overlapIntervals: intersections(microphoneIntervals, systemIntervals),
            usesLegacyTimelineFallback: !legacySegments.isEmpty
        )
    }

    private static func timelineProjection(
        from analysis: Analysis,
        timelineDuration: TimeInterval
    ) -> TimelineProjection {
        var isCondensed = false
        let intervals = sources.flatMap { source in
            let projection = displayIntervals(
                analysis.mergedBySource[source] ?? [],
                timelineDuration: timelineDuration
            )
            isCondensed = isCondensed || projection.isCondensed
            return projection.intervals.map {
                MeetingConversationMetrics.TimelineInterval(
                    source: source,
                    start: $0.start,
                    end: $0.end
                )
            }
        }
        let overlapProjection = displayIntervals(
            analysis.overlapIntervals,
            timelineDuration: timelineDuration
        )
        isCondensed = isCondensed || overlapProjection.isCondensed
        let overlaps = overlapProjection.intervals.map {
            MeetingConversationMetrics.OverlapInterval(start: $0.start, end: $0.end)
        }
        return TimelineProjection(
            intervals: intervals,
            overlaps: overlaps,
            overlapCount: analysis.overlapIntervals.count,
            isCondensed: isCondensed
        )
    }

    private static func validSessions(
        from sessions: [MeetingConversationMetricsInput.Session]
    ) -> [UUID: ValidSession] {
        Dictionary(
            uniqueKeysWithValues: sessions.compactMap { session in
                guard let duration = session.duration,
                      duration.isFinite,
                      duration >= 0,
                      session.offsetSeconds.isFinite else { return nil }
                return (
                    session.id,
                    ValidSession(
                        startedAt: session.startedAt,
                        duration: duration,
                        offsetSeconds: session.offsetSeconds
                    )
                )
            }
        )
    }

    private static func recordingDuration(
        for input: MeetingConversationMetricsInput,
        analysis: Analysis
    ) -> TimeInterval {
        let recordedDuration: TimeInterval = if input.sessions.isEmpty {
            max(0, input.meetingDuration ?? 0)
        } else {
            input.sessions.reduce(0) { result, session in
                guard let duration = session.duration, duration.isFinite else { return result }
                return result + max(0, duration)
            }
        }
        guard analysis.usesLegacyTimelineFallback else { return recordedDuration }
        return max(recordedDuration, analysis.allIntervals.last?.end ?? 0)
    }

    private static func sourceMetrics(
        accumulators: [RecordingAudioSource: SourceAccumulator],
        mergedBySource: [RecordingAudioSource: [Interval]]
    ) -> [MeetingConversationMetrics.SourceMetrics] {
        sources.map { source in
            let accumulator = accumulators[source, default: SourceAccumulator()]
            return MeetingConversationMetrics.SourceMetrics(
                source: source,
                speechDuration: duration(of: mergedBySource[source] ?? []),
                normalizedCharacterCount: accumulator.normalizedCharacterCount,
                segmentCount: accumulator.segmentCount,
                unmeasurableSegmentCount: accumulator.unmeasurableSegmentCount
            )
        }
    }

    private static func interval(
        for segment: MeetingConversationMetricsInput.Segment,
        validSessions: [UUID: ValidSession],
        legacyOrigin: Date?,
        legacyBaseOffset: TimeInterval
    ) -> Interval? {
        guard let endTime = segment.endTime else { return nil }

        let start: TimeInterval
        let end: TimeInterval
        if let sessionId = segment.sessionId,
           let session = validSessions[sessionId] {
            let sessionStart = session.offsetSeconds
            let sessionEnd = sessionStart + session.duration
            start = min(max(sessionStart + segment.startTime.timeIntervalSince(session.startedAt), sessionStart), sessionEnd)
            end = min(max(sessionStart + endTime.timeIntervalSince(session.startedAt), sessionStart), sessionEnd)
        } else if let legacyOrigin {
            start = legacyBaseOffset + segment.startTime.timeIntervalSince(legacyOrigin)
            end = legacyBaseOffset + endTime.timeIntervalSince(legacyOrigin)
        } else {
            return nil
        }

        guard start.isFinite, end.isFinite, end > start else { return nil }
        return Interval(start: start, end: end)
    }

    private static func merged(
        _ intervals: [Interval],
        mergeGap: TimeInterval = 0
    ) -> [Interval] {
        let sorted = intervals.sorted {
            if $0.start == $1.start {
                return $0.end < $1.end
            }
            return $0.start < $1.start
        }
        guard var current = sorted.first else { return [] }
        var result: [Interval] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end + mergeGap {
                current = Interval(start: current.start, end: max(current.end, interval.end))
            } else {
                result.append(current)
                current = interval
            }
        }
        result.append(current)
        return result
    }

    private static func displayIntervals(
        _ intervals: [Interval],
        timelineDuration: TimeInterval
    ) -> DisplayIntervals {
        guard intervals.count > maximumTimelineIntervalsPerLane,
              timelineDuration > 0 else {
            return DisplayIntervals(intervals: intervals, isCondensed: false)
        }
        let bucketDuration = timelineDuration / Double(maximumTimelineIntervalsPerLane)
        let bucketed = intervals.map { interval in
            let start = floor(interval.start / bucketDuration) * bucketDuration
            let end = min(timelineDuration, max(
                ceil(interval.end / bucketDuration) * bucketDuration,
                start + bucketDuration
            ))
            return Interval(start: start, end: end)
        }
        return DisplayIntervals(intervals: merged(bucketed), isCondensed: true)
    }

    private static func normalizedSpeechMergeGap(_ speechMergeGap: TimeInterval) -> TimeInterval {
        guard speechMergeGap.isFinite else { return 0 }
        return max(0, speechMergeGap)
    }

    private static func duration(of intervals: [Interval]) -> TimeInterval {
        intervals.reduce(0) { $0 + $1.duration }
    }

    private static func intersections(_ lhs: [Interval], _ rhs: [Interval]) -> [Interval] {
        var lhsIndex = 0
        var rhsIndex = 0
        var result: [Interval] = []

        while lhsIndex < lhs.count, rhsIndex < rhs.count {
            let left = lhs[lhsIndex]
            let right = rhs[rhsIndex]
            let start = max(left.start, right.start)
            let end = min(left.end, right.end)
            if end > start {
                result.append(Interval(start: start, end: end))
            }
            if left.end <= right.end {
                lhsIndex += 1
            } else {
                rhsIndex += 1
            }
        }
        return result
    }
}
