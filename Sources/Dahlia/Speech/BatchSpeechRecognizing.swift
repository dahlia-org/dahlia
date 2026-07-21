@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

struct BatchSpeechRecognition: Sendable {
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let text: String
}

protocol BatchSpeechRecognizing: Sendable {
    func recognize(audioURL: URL, locale: Locale) async throws -> [BatchSpeechRecognition]
}

struct AppleBatchSpeechRecognizer: BatchSpeechRecognizing {
    func recognize(audioURL: URL, locale: Locale) async throws -> [BatchSpeechRecognition] {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await installAssetsIfNeeded(for: transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: audioURL)

        let resultTask = Task<[BatchSpeechRecognition], Error> {
            var recognitions: [BatchSpeechRecognition] = []
            for try await result in transcriber.results where result.isFinal {
                recognitions.append(
                    BatchSpeechRecognition(
                        startSeconds: result.range.start.seconds,
                        endSeconds: result.range.end.seconds,
                        text: String(result.text.characters)
                    )
                )
            }
            return recognitions
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

    private func installAssetsIfNeeded(for transcriber: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status < .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
}
