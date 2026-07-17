@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// CAFの指定rangeを精度優先のSpeechTranscriberで文字起こしする。
enum BatchSpeechTranscriberService {
    static func transcribe(_ request: BatchSpeechTranscriptionRequest) async throws -> [TranscriptSegment] {
        guard request.startFrame >= 0, request.frameCount > 0 else { return [] }
        let rangeURL = try extractRange(
            from: request.audioURL,
            startFrame: request.startFrame,
            frameCount: request.frameCount
        )
        defer { try? FileManager.default.removeItem(at: rangeURL) }

        let transcriber = SpeechTranscriber(locale: request.locale, preset: .transcription)
        try await installAssetsIfNeeded(for: transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: rangeURL)

        let resultTask = Task<[TranscriptSegment], Error> {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                guard let text = SpeechTranscriberService.normalizedTranscriptText(String(result.text.characters)) else {
                    continue
                }
                let startSeconds = result.range.start.seconds
                let endSeconds = result.range.end.seconds
                let absoluteStart = request.recordingStartTime.addingTimeInterval(
                    request.sessionOffsetSeconds + (startSeconds.isFinite ? startSeconds : 0)
                )
                let absoluteEnd = request.recordingStartTime.addingTimeInterval(
                    request.sessionOffsetSeconds + (endSeconds.isFinite ? endSeconds : 0)
                )
                segments.append(
                    TranscriptSegment(
                        sessionId: request.recordingSessionId,
                        startTime: absoluteStart,
                        endTime: absoluteEnd,
                        text: text,
                        isConfirmed: true,
                        speakerLabel: request.source.speakerLabel
                    )
                )
            }
            return segments
        }

        do {
            guard let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) else {
                throw BatchSpeechTranscriberError.analysisDidNotAdvance
            }
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
            return try await resultTask.value
        } catch {
            await analyzer.cancelAndFinishNow()
            resultTask.cancel()
            throw error
        }
    }

    private static func installAssetsIfNeeded(for transcriber: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status < .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
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
