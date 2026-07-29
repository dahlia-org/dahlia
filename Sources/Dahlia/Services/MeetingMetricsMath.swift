import Foundation

enum MeetingMetricsMath {
    struct Interval: Sendable, Equatable {
        let start: Date
        let end: Date

        var duration: Double {
            end.timeIntervalSince(start)
        }
    }

    static func mergedIntervals(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
        var merged: [Interval] = []
        for interval in sorted where interval.end > interval.start {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }
            if interval.start <= last.end {
                merged[merged.count - 1] = Interval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    static func speakingSeconds(_ intervals: [Interval]) -> Double {
        mergedIntervals(intervals).reduce(0) { $0 + $1.duration }
    }

    static func overlapSeconds(
        microphone: [Interval],
        system: [Interval],
        minimumEpisodeSeconds: Double = MeetingMetricsConstants.minimumOverlapEpisodeSeconds
    ) -> Double {
        let microphone = mergedIntervals(microphone)
        let system = mergedIntervals(system)
        var microphoneIndex = 0
        var systemIndex = 0
        var fragments: [Interval] = []
        while microphoneIndex < microphone.count, systemIndex < system.count {
            let start = max(microphone[microphoneIndex].start, system[systemIndex].start)
            let end = min(microphone[microphoneIndex].end, system[systemIndex].end)
            if end > start {
                fragments.append(Interval(start: start, end: end))
            }
            if microphone[microphoneIndex].end < system[systemIndex].end {
                microphoneIndex += 1
            } else {
                systemIndex += 1
            }
        }
        return mergedIntervals(fragments)
            .filter { $0.duration >= minimumEpisodeSeconds }
            .reduce(0) { $0 + $1.duration }
    }

    static func turnCount(_ intervals: [Interval], gapSeconds: Double = MeetingMetricsConstants.turnGapSeconds) -> Int {
        let sorted = intervals.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
        var count = 0
        var currentEnd: Date?
        for interval in sorted where interval.end > interval.start {
            if let existingEnd = currentEnd, interval.start.timeIntervalSince(existingEnd) <= gapSeconds {
                currentEnd = max(existingEnd, interval.end)
            } else {
                count += 1
                currentEnd = interval.end
            }
        }
        return count
    }
}
