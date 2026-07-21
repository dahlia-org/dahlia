import Foundation

enum BatchTranscriptionAudioRangePlanner {
    static func ranges(
        for verified: RecordingAudioStore.VerifiedSegment,
        mode: BatchLanguageDetectionMode
    ) throws -> [BatchTranscriptionAudioRange] {
        switch mode {
        case .manual:
            return try verified.ranges.map { range in
                guard let frameCount = range.frameCount else {
                    throw BatchSpeechTranscriberError.invalidAudioRange
                }
                return BatchTranscriptionAudioRange(
                    startFrame: range.startFrame,
                    frameCount: frameCount,
                    sessionOffsetSeconds: range.sessionOffsetSeconds,
                    recordedLocaleIdentifiers: [range.localeIdentifier]
                )
            }
        case .automatic:
            guard let first = verified.ranges.first,
                  let firstFrameCount = first.frameCount else {
                throw BatchSpeechTranscriberError.invalidAudioRange
            }
            var endFrame = first.startFrame + firstFrameCount
            for range in verified.ranges.dropFirst() {
                guard let frameCount = range.frameCount,
                      range.startFrame == endFrame else {
                    throw BatchSpeechTranscriberError.invalidAudioRange
                }
                endFrame += frameCount
            }
            return [
                BatchTranscriptionAudioRange(
                    startFrame: first.startFrame,
                    frameCount: endFrame - first.startFrame,
                    sessionOffsetSeconds: first.sessionOffsetSeconds,
                    recordedLocaleIdentifiers: verified.ranges.map(\.localeIdentifier)
                ),
            ]
        }
    }
}
