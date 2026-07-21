@preconcurrency import AVFoundation
import Foundation

/// CAFの指定rangeを精度優先のSpeechTranscriberで文字起こしする。
enum BatchSpeechTranscriberService {
    private struct PreparedAudio: Sendable {
        let url: URL
        let isTemporary: Bool
    }

    static func transcribe(
        _ request: BatchSpeechTranscriptionRequest,
        languageDetector: (any BatchLanguageDetecting)? = nil,
        speechRecognizer: any BatchSpeechRecognizing = AppleBatchSpeechRecognizer(),
        fallbackLocaleIdentifier: String = "en",
        onLanguageFallback: @escaping @Sendable (BatchLanguageFallback) async -> Void = { _ in }
    ) async throws -> BatchSpeechTranscriptionResult {
        guard request.startFrame >= 0, request.frameCount > 0 else {
            return BatchSpeechTranscriptionResult(
                segments: [],
                localeIdentifier: request.recordedLocaleIdentifiers.first ?? "",
                languageFallback: nil
            )
        }
        try Task.checkCancellation()
        let preparationTask = Task.detached(priority: .utility) {
            try prepareAudio(
                from: request.audioURL,
                startFrame: request.startFrame,
                frameCount: request.frameCount
            )
        }
        let preparedAudio = try await withTaskCancellationHandler {
            try await preparationTask.value
        } onCancel: {
            preparationTask.cancel()
        }
        defer {
            if preparedAudio.isTemporary {
                try? FileManager.default.removeItem(at: preparedAudio.url)
            }
        }

        let resolution = try await resolvedLocale(
            for: request,
            audioURL: preparedAudio.url,
            languageDetector: languageDetector,
            fallbackLocaleIdentifier: fallbackLocaleIdentifier
        )
        if let fallback = resolution.fallback {
            await onLanguageFallback(fallback)
        }
        let recognitions = try await speechRecognizer.recognize(audioURL: preparedAudio.url, locale: resolution.locale)
        let segments = recognitions.compactMap { recognition -> TranscriptSegment? in
            guard let text = SpeechTranscriberService.normalizedTranscriptText(recognition.text) else { return nil }
            let absoluteStart = request.recordingStartTime.addingTimeInterval(
                request.sessionOffsetSeconds + (recognition.startSeconds.isFinite ? recognition.startSeconds : 0)
            )
            let absoluteEnd = request.recordingStartTime.addingTimeInterval(
                request.sessionOffsetSeconds + (recognition.endSeconds.isFinite ? recognition.endSeconds : 0)
            )
            return TranscriptSegment(
                sessionId: request.recordingSessionId,
                startTime: absoluteStart,
                endTime: absoluteEnd,
                text: text,
                isConfirmed: true,
                speakerLabel: request.source.speakerLabel
            )
        }
        return BatchSpeechTranscriptionResult(
            segments: segments,
            localeIdentifier: resolution.locale.identifier,
            languageFallback: resolution.fallback
        )
    }

    private static func resolvedLocale(
        for request: BatchSpeechTranscriptionRequest,
        audioURL: URL,
        languageDetector: (any BatchLanguageDetecting)?,
        fallbackLocaleIdentifier: String
    ) async throws -> BatchLanguageResolution {
        if request.languageDetectionMode == .manual,
           let recordedLocaleIdentifier = request.recordedLocaleIdentifiers.first {
            return BatchLanguageResolution(
                locale: Locale(identifier: recordedLocaleIdentifier),
                fallback: nil
            )
        }
        guard request.languageDetectionMode == .automatic else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        guard let languageDetector else {
            throw BatchSpeechTranscriberError.languageDetectionFailed
        }

        return try await BatchLanguageDetectionService.resolveLocale(
            audioURL: audioURL,
            recordedLocaleIdentifiers: request.recordedLocaleIdentifiers,
            supportedLocales: request.supportedLocales,
            languageDetector: languageDetector,
            fallbackLocaleIdentifier: fallbackLocaleIdentifier,
            allowedLanguageIdentifiers: request.allowedLanguageIdentifiers
        )
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
