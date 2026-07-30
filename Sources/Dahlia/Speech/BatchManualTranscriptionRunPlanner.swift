@preconcurrency import AVFoundation
import Foundation

enum BatchManualTranscriptionRunPlanner {
    typealias AudioFormatProvider = (RecordingAudioStore.VerifiedSegment) throws -> AVAudioFormat

    private struct Candidate {
        let slice: BatchSpeechAudioSlice
        let localeIdentifier: String
        let source: RecordingAudioSource
        let recordingSessionId: UUID
        let sessionOffsetSeconds: TimeInterval
        let audioFormat: AVAudioFormat
        let fileIndex: Int

        var endOffsetSeconds: TimeInterval {
            sessionOffsetSeconds + Double(slice.frameCount) / audioFormat.sampleRate
        }
    }

    static func runs(
        verifiedSegments: [RecordingAudioStore.VerifiedSegment],
        recordingStartTime: Date,
        audioFormatProvider: AudioFormatProvider = {
            try AVAudioFile(forReading: $0.url).processingFormat
        }
    ) throws -> [BatchManualTranscriptionRun] {
        let candidates = try verifiedSegments.enumerated().flatMap { fileIndex, verified in
            let audioFormat = try audioFormatProvider(verified)
            return try verified.ranges.compactMap { range -> Candidate? in
                guard let frameCount = range.frameCount,
                      range.startFrame >= 0,
                      frameCount >= 0,
                      audioFormat.sampleRate > 0 else {
                    throw BatchSpeechTranscriberError.invalidAudioRange
                }
                guard frameCount > 0 else { return nil }
                return Candidate(
                    slice: BatchSpeechAudioSlice(
                        audioURL: verified.url,
                        startFrame: range.startFrame,
                        frameCount: frameCount
                    ),
                    localeIdentifier: range.localeIdentifier,
                    source: verified.segment.source,
                    recordingSessionId: verified.segment.recordingSessionId,
                    sessionOffsetSeconds: range.sessionOffsetSeconds,
                    audioFormat: audioFormat,
                    fileIndex: fileIndex
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.source == rhs.source {
                return lhs.sessionOffsetSeconds < rhs.sessionOffsetSeconds
            }
            return lhs.source.rawValue < rhs.source.rawValue
        }

        var grouped: [[Candidate]] = []
        for candidate in candidates {
            if let previous = grouped.last?.last,
               canJoin(previous, candidate) {
                grouped[grouped.count - 1].append(candidate)
            } else {
                grouped.append([candidate])
            }
        }
        return grouped.compactMap { candidates in
            guard let first = candidates.first else { return nil }
            return BatchManualTranscriptionRun(
                slices: candidates.map(\.slice),
                localeIdentifier: first.localeIdentifier,
                source: first.source,
                recordingSessionId: first.recordingSessionId,
                recordingStartTime: recordingStartTime,
                sessionOffsetSeconds: first.sessionOffsetSeconds,
                fileIndices: Array(Set(candidates.map(\.fileIndex))).sorted()
            )
        }
    }

    private static func canJoin(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        guard lhs.recordingSessionId == rhs.recordingSessionId,
              lhs.source == rhs.source,
              lhs.localeIdentifier == rhs.localeIdentifier,
              lhs.audioFormat == rhs.audioFormat else {
            return false
        }
        let tolerance = 0.5 / lhs.audioFormat.sampleRate
        return abs(lhs.endOffsetSeconds - rhs.sessionOffsetSeconds) <= tolerance
    }
}
