import Foundation

enum BatchManualSpeechTranscriberService {
    static func transcribe(
        _ run: BatchManualTranscriptionRun,
        speechRecognizer: any BatchSpeechRecognizing,
        onFileConsumed: @escaping @Sendable (Int) async -> Void = { _ in }
    ) async throws -> BatchSpeechTranscriptionResult {
        guard !run.slices.isEmpty,
              run.slices.count == run.sliceFileIndices.count else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        let lastSliceIndexByFile = Dictionary(
            run.sliceFileIndices.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { _, last in last }
        )
        let recognitions = try await speechRecognizer.recognize(
            audioSlices: run.slices,
            locale: Locale(identifier: run.localeIdentifier),
            onSliceConsumed: { sliceIndex in
                guard run.sliceFileIndices.indices.contains(sliceIndex) else { return }
                let fileIndex = run.sliceFileIndices[sliceIndex]
                guard lastSliceIndexByFile[fileIndex] == sliceIndex else { return }
                await onFileConsumed(fileIndex)
            }
        )
        let segments = BatchSpeechTranscriberService.transcriptSegments(
            from: recognitions,
            recordingSessionId: run.recordingSessionId,
            recordingStartTime: run.recordingStartTime,
            sessionOffsetSeconds: run.sessionOffsetSeconds,
            source: run.source
        )
        return BatchSpeechTranscriptionResult(
            segments: segments,
            localeIdentifier: run.localeIdentifier,
            languageFallback: nil
        )
    }
}
