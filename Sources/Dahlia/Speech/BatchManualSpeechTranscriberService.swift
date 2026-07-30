import Foundation

enum BatchManualSpeechTranscriberService {
    static func transcribe(
        _ run: BatchManualTranscriptionRun,
        speechRecognizer: any BatchSpeechRecognizing
    ) async throws -> BatchSpeechTranscriptionResult {
        guard !run.slices.isEmpty else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        let recognitions = try await speechRecognizer.recognize(
            audioSlices: run.slices,
            locale: Locale(identifier: run.localeIdentifier)
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
