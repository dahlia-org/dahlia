@preconcurrency import AVFoundation
import Foundation

/// CAFの指定rangeを精度優先のSpeechTranscriberで文字起こしする。
enum BatchSpeechTranscriberService {
    private struct PreparedAudio: Sendable {
        let url: URL
        let isTemporary: Bool
    }

    static func resolveLocale(
        for request: BatchSpeechTranscriptionRequest,
        languageDetector: any BatchLanguageDetecting,
        onLanguageFallback: @escaping @Sendable (BatchLanguageFallback) async -> Void = { _ in }
    ) async throws -> BatchLanguageResolution {
        guard request.startFrame >= 0, request.frameCount > 0 else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        try Task.checkCancellation()
        let preparedAudio = try await preparedAudio(for: request)
        defer {
            if preparedAudio.isTemporary {
                try? FileManager.default.removeItem(at: preparedAudio.url)
            }
        }
        let resolution = try await BatchLanguageDetectionService.resolveLocale(
            audioURL: preparedAudio.url,
            recordedLocaleIdentifiers: request.recordedLocaleIdentifiers,
            supportedLocales: request.supportedLocales,
            detectionCandidateLocales: request.automaticLanguageCandidateLocales,
            languageDetector: languageDetector,
            allowedLanguageIdentifiers: request.allowedLanguageIdentifiers
        )
        if let fallback = resolution.fallback {
            await onLanguageFallback(fallback)
        }
        return resolution
    }

    static func transcriptSegments(
        from recognitions: [BatchSpeechRecognition],
        audioFeatures: [TranscriptAudioFeatures?] = [],
        recordingSessionId: UUID,
        recordingStartTime: Date,
        sessionOffsetSeconds: TimeInterval,
        source: RecordingAudioSource
    ) -> [TranscriptSegment] {
        recognitions.enumerated().compactMap { index, recognition -> TranscriptSegment? in
            guard let text = SpeechTranscriberService.normalizedTranscriptText(recognition.text) else { return nil }
            let absoluteStart = recordingStartTime.addingTimeInterval(
                sessionOffsetSeconds + (recognition.startSeconds.isFinite ? recognition.startSeconds : 0)
            )
            let absoluteEnd = recordingStartTime.addingTimeInterval(
                sessionOffsetSeconds + (recognition.endSeconds.isFinite ? recognition.endSeconds : 0)
            )
            return TranscriptSegment(
                sessionId: recordingSessionId,
                startTime: absoluteStart,
                endTime: absoluteEnd,
                text: text,
                isConfirmed: true,
                speakerLabel: source.speakerLabel,
                audioFeatures: audioFeatures.indices.contains(index) ? audioFeatures[index] : nil
            )
        }
    }

    private static func preparedAudio(
        for request: BatchSpeechTranscriptionRequest
    ) async throws -> PreparedAudio {
        let preparationTask = Task.detached(priority: .utility) {
            try prepareAudio(
                from: request.audioURL,
                startFrame: request.startFrame,
                frameCount: request.frameCount
            )
        }
        return try await withTaskCancellationHandler {
            try await preparationTask.value
        } onCancel: {
            preparationTask.cancel()
        }
    }

    private static func prepareAudio(from sourceURL: URL, startFrame: Int64, frameCount: Int64) throws -> PreparedAudio {
        let source = try AVAudioFile(forReading: sourceURL)
        guard startFrame < source.length else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        let availableFrames = min(frameCount, source.length - startFrame)
        guard availableFrames > 0 else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        if startFrame == 0, frameCount == source.length {
            return PreparedAudio(url: sourceURL, isTemporary: false)
        }
        return try PreparedAudio(
            url: extractRange(from: source, startFrame: startFrame, frameCount: availableFrames),
            isTemporary: true
        )
    }

    private static func extractRange(from source: AVAudioFile, startFrame: Int64, frameCount: Int64) throws -> URL {
        let destinationURL = FileManager.default.temporaryDirectory
            .appending(path: "dahlia-batch-\(UUID.v7().uuidString).caf")
        source.framePosition = startFrame

        do {
            let destination = try AVAudioFile(
                forWriting: destinationURL,
                settings: source.processingFormat.settings,
                commonFormat: source.processingFormat.commonFormat,
                interleaved: source.processingFormat.isInterleaved
            )
            let capacity: AVAudioFrameCount = 16384
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: capacity) else {
                throw BatchSpeechTranscriberError.audioFormatUnavailable
            }

            var remaining = frameCount
            while remaining > 0 {
                try Task.checkCancellation()
                let requested = AVAudioFrameCount(min(Int64(capacity), remaining))
                try source.read(into: buffer, frameCount: requested)
                guard buffer.frameLength > 0 else {
                    throw BatchSpeechTranscriberError.invalidAudioRange
                }
                try destination.write(from: buffer)
                remaining -= Int64(buffer.frameLength)
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        return destinationURL
    }
}
