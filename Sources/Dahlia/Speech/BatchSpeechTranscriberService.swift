@preconcurrency import AVFoundation
import Foundation

/// CAFの指定rangeを精度優先のSpeechTranscriberで文字起こしする。
enum BatchSpeechTranscriberService {
    static func transcribe(
        _ request: BatchSpeechTranscriptionRequest,
        languageDetector: (any BatchLanguageDetecting)? = nil,
        speechRecognizer: any BatchSpeechRecognizing = AppleBatchSpeechRecognizer()
    ) async throws -> BatchSpeechTranscriptionResult {
        guard request.startFrame >= 0, request.frameCount > 0 else {
            return BatchSpeechTranscriptionResult(
                segments: [],
                localeIdentifier: request.recordedLocaleIdentifiers.first ?? ""
            )
        }
        let rangeURL = try extractRange(
            from: request.audioURL,
            startFrame: request.startFrame,
            frameCount: request.frameCount
        )
        defer { try? FileManager.default.removeItem(at: rangeURL) }

        let locale = try await resolvedLocale(
            for: request,
            rangeURL: rangeURL,
            languageDetector: languageDetector
        )
        let recognitions = try await speechRecognizer.recognize(audioURL: rangeURL, locale: locale)
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
            localeIdentifier: locale.identifier
        )
    }

    private static func resolvedLocale(
        for request: BatchSpeechTranscriptionRequest,
        rangeURL: URL,
        languageDetector: (any BatchLanguageDetecting)?
    ) async throws -> Locale {
        if request.languageDetectionMode == .manual,
           let recordedLocaleIdentifier = request.recordedLocaleIdentifiers.first {
            return Locale(identifier: recordedLocaleIdentifier)
        }
        guard request.languageDetectionMode == .automatic else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        guard let languageDetector else {
            throw BatchSpeechTranscriberError.languageDetectionFailed
        }

        return try await BatchLanguageDetectionService.resolveLocale(
            audioURL: rangeURL,
            recordedLocaleIdentifiers: request.recordedLocaleIdentifiers,
            supportedLocales: request.supportedLocales,
            languageDetector: languageDetector
        )
    }

    private static func extractRange(from sourceURL: URL, startFrame: Int64, frameCount: Int64) throws -> URL {
        let source = try AVAudioFile(forReading: sourceURL)
        guard startFrame < source.length else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        let availableFrames = min(frameCount, source.length - startFrame)
        guard availableFrames > 0 else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }

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

            var remaining = availableFrames
            while remaining > 0 {
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
