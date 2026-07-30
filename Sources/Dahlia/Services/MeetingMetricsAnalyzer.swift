import Foundation
import GRDB

enum MeetingMetricsAnalyzer {
    struct Segment: Decodable, FetchableRecord, Sendable {
        let id: UUID
        let startTime: Date
        let endTime: Date?
        let text: String
        let speakerLabel: String?
    }

    struct Accumulator {
        private struct SourceState {
            var activeEnd: Date?
            var speakingSeconds = 0.0
            var characterCount = 0
            var cjkCharacterCount = 0
            var turnCount = 0
            var currentTurnEnd: Date?
        }

        private let meetingId: UUID
        private let revision: Int64
        private var isPartialAnalysis = false
        private var sourceStates: [MetricsSource: SourceState] = [:]
        private var timelineCursor: Date?
        private var conversationTalkSeconds = 0.0
        private var retainedOverlapSeconds = 0.0
        private var currentOverlapEpisodeSeconds = 0.0
        private(set) var confirmedSegmentCount = 0
        private(set) var validSegmentCount = 0
        private(set) var invalidDurationSegmentCount = 0
        private(set) var unknownSourceSegmentCount = 0
        private(set) var totalCharacterCount = 0
        private(set) var validCharacterCount = 0
        private(set) var unknownSourceCharacterCount = 0

        init(meetingId: UUID, revision: Int64) {
            self.meetingId = meetingId
            self.revision = revision
        }

        mutating func append(_ record: Segment) {
            let characters = record.text.filter { !$0.isWhitespace }
            guard !characters.isEmpty else { return }
            confirmedSegmentCount += 1
            let source = MetricsSource(speakerLabel: record.speakerLabel)
            let characterCount = characters.count
            totalCharacterCount += characterCount
            if source == .unknown {
                unknownSourceSegmentCount += 1
                unknownSourceCharacterCount += characterCount
            }

            guard let end = record.endTime else {
                invalidDurationSegmentCount += 1
                return
            }
            let duration = end.timeIntervalSince(record.startTime)
            guard duration.isFinite, duration > 0 else {
                invalidDurationSegmentCount += 1
                return
            }

            validSegmentCount += 1
            validCharacterCount += characterCount
            advanceTimeline(to: record.startTime)

            var state = sourceStates[source, default: SourceState()]
            state.activeEnd = max(state.activeEnd ?? end, end)
            state.characterCount += characterCount
            state.cjkCharacterCount += characters.reduce(0) { count, character in
                count + (isCJK(character) ? 1 : 0)
            }
            if let currentTurnEnd = state.currentTurnEnd,
               record.startTime.timeIntervalSince(currentTurnEnd) <= MeetingMetricsConstants.turnGapSeconds {
                state.currentTurnEnd = max(currentTurnEnd, end)
            } else {
                state.turnCount += 1
                state.currentTurnEnd = end
            }
            sourceStates[source] = state
        }

        mutating func markPartialAnalysis() {
            isPartialAnalysis = true
        }

        mutating func finish() -> MeetingMetricsResult? {
            guard validSegmentCount > 0 else { return nil }
            if let finalEnd = sourceStates.values.compactMap(\.activeEnd).max() {
                advanceTimeline(to: finalEnd)
            }
            retainCurrentOverlapEpisodeIfNeeded()

            let rows = MetricsSource.allCases.compactMap { source -> MeetingSourceMetricsRow? in
                guard let state = sourceStates[source], state.characterCount > 0 else { return nil }
                let pace = state.speakingSeconds > 0
                    ? Double(state.characterCount) / (state.speakingSeconds / 60)
                    : nil
                return MeetingSourceMetricsRow(
                    meetingId: meetingId,
                    source: source,
                    speakingSeconds: state.speakingSeconds,
                    characterCount: state.characterCount,
                    cjkCharacterCount: state.cjkCharacterCount,
                    turnCount: state.turnCount,
                    charactersPerMinute: pace
                )
            }
            let microphoneSeconds = rows.first { $0.source == .microphone }?.speakingSeconds ?? 0
            let systemSeconds = rows.first { $0.source == .system }?.speakingSeconds ?? 0
            let comparisonGatePassed = microphoneSeconds >= MeetingMetricsConstants.minimumSourceSpeakingSeconds
                && systemSeconds >= MeetingMetricsConstants.minimumSourceSpeakingSeconds
            let balance = comparisonGatePassed ? microphoneSeconds / (microphoneSeconds + systemSeconds) : nil

            return MeetingMetricsResult(
                meetingId: meetingId,
                metricsVersion: MeetingMetricsConstants.metricsVersion,
                transcriptRevision: revision,
                conversationTalkSeconds: conversationTalkSeconds,
                overlapSeconds: comparisonGatePassed ? retainedOverlapSeconds : nil,
                talkBalance: balance,
                confirmedSegmentCount: confirmedSegmentCount,
                validSegmentCount: validSegmentCount,
                invalidDurationSegmentCount: invalidDurationSegmentCount,
                unknownSourceSegmentCount: unknownSourceSegmentCount,
                totalCharacterCount: totalCharacterCount,
                validCharacterCount: validCharacterCount,
                unknownSourceCharacterCount: unknownSourceCharacterCount,
                sourceRows: rows,
                isPartialAnalysis: isPartialAnalysis
            )
        }

        private mutating func advanceTimeline(to target: Date) {
            guard var cursor = timelineCursor else {
                timelineCursor = target
                return
            }
            guard target >= cursor else { return }
            while cursor < target {
                let activeSources = MetricsSource.allCases.filter {
                    guard let end = sourceStates[$0]?.activeEnd else { return false }
                    return end > cursor
                }
                let nextEnd = activeSources.compactMap { sourceStates[$0]?.activeEnd }.min() ?? target
                let boundary = min(target, nextEnd)
                let duration = boundary.timeIntervalSince(cursor)
                if duration > 0 {
                    for source in activeSources {
                        sourceStates[source]?.speakingSeconds += duration
                    }
                    if !activeSources.isEmpty {
                        conversationTalkSeconds += duration
                    }
                    if activeSources.contains(.microphone), activeSources.contains(.system) {
                        currentOverlapEpisodeSeconds += duration
                    } else {
                        retainCurrentOverlapEpisodeIfNeeded()
                    }
                }
                cursor = boundary
                for source in MetricsSource.allCases where sourceStates[source]?.activeEnd == cursor {
                    sourceStates[source]?.activeEnd = nil
                }
            }
            timelineCursor = target
        }

        private mutating func retainCurrentOverlapEpisodeIfNeeded() {
            if currentOverlapEpisodeSeconds >= MeetingMetricsConstants.minimumOverlapEpisodeSeconds {
                retainedOverlapSeconds += currentOverlapEpisodeSeconds
            }
            currentOverlapEpisodeSeconds = 0
        }

        private func isCJK(_ character: Character) -> Bool {
            guard let scalar = character.unicodeScalars.first?.value else { return false }
            return (0x3040 ... 0x30FF).contains(scalar)
                || (0x3400 ... 0x4DBF).contains(scalar)
                || (0x4E00 ... 0x9FFF).contains(scalar)
                || (0xF900 ... 0xFAFF).contains(scalar)
                || (0xFF66 ... 0xFF9F).contains(scalar)
        }
    }
}
