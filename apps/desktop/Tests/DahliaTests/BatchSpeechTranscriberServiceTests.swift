@preconcurrency import AVFoundation
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchSpeechTranscriberServiceTests {
        @Test
        func automaticModePassesConfiguredLanguageCandidatesToDetector() async throws {
            let audioURL = try makeAudioFile(name: "candidates")
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let detector = SequenceLanguageDetector(detections: ["ja"])
            let transcriptionRequest = request(
                audioURL: audioURL,
                recordedLocaleIdentifier: "ja_JP",
                allowedLanguageIdentifiers: ["en", "ja"]
            )

            _ = try await BatchSpeechTranscriberService.resolveLocale(
                for: transcriptionRequest,
                languageDetector: detector
            )

            #expect(await detector.allowedLanguageIdentifiers == [["en", "ja"]])
        }

        @Test
        func partialRangeLanguageResolutionRemovesTemporaryCAF() async throws {
            let audioURL = try makeAudioFile(name: "partial-language-resolution")
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let detector = SequenceLanguageDetector(detections: ["ja"])

            let resolution = try await BatchSpeechTranscriberService.resolveLocale(
                for: partialRequest(audioURL: audioURL),
                languageDetector: detector
            )

            let temporaryURL = try #require(await detector.audioURLs.first)
            #expect(resolution.locale.identifier == "ja_JP")
            #expect(temporaryURL != audioURL)
            #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
            #expect(FileManager.default.fileExists(atPath: audioURL.path))
        }

        @Test
        func cancellationRemovesPartialRangeTemporaryCAF() async throws {
            let audioURL = try makeAudioFile(name: "cancelled-partial")
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let detector = CancellableLanguageDetector()
            let transcriptionTask = Task {
                try await BatchSpeechTranscriberService.resolveLocale(
                    for: partialRequest(audioURL: audioURL),
                    languageDetector: detector
                )
            }

            try await waitUntil { await detector.audioURL != nil }
            let temporaryURL = try #require(await detector.audioURL)
            transcriptionTask.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await transcriptionTask.value
            }

            #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
            #expect(FileManager.default.fileExists(atPath: audioURL.path))
        }

        @Test
        func languageInferenceFailureUsesEnglishAndRemovesPartialRangeTemporaryCAF() async throws {
            let audioURL = try makeAudioFile(name: "failed-partial-detection")
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let detector = SequenceLanguageDetector(detections: [])

            let resolution = try await BatchSpeechTranscriberService.resolveLocale(
                for: partialRequest(audioURL: audioURL),
                languageDetector: detector
            )

            let temporaryURL = try #require(await detector.audioURLs.first)
            #expect(resolution.locale.identifier == "en_US")
            #expect(resolution.fallback == .inferenceFailure)
            #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
            #expect(FileManager.default.fileExists(atPath: audioURL.path))
        }

        private func partialRequest(audioURL: URL) -> BatchSpeechTranscriptionRequest {
            BatchSpeechTranscriptionRequest(
                audioURL: audioURL,
                startFrame: 80,
                frameCount: 160,
                recordedLocaleIdentifiers: ["ja_JP"],
                supportedLocales: [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")]
            )
        }

        private func request(
            audioURL: URL,
            recordedLocaleIdentifier: String,
            allowedLanguageIdentifiers: Set<String>? = nil
        ) -> BatchSpeechTranscriptionRequest {
            BatchSpeechTranscriptionRequest(
                audioURL: audioURL,
                startFrame: 0,
                frameCount: 320,
                recordedLocaleIdentifiers: [recordedLocaleIdentifier],
                supportedLocales: [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")],
                allowedLanguageIdentifiers: allowedLanguageIdentifiers
            )
        }

        private func makeAudioFile(name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-batch-transcriber-\(name)-\(UUID.v7().uuidString).caf")
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
            buffer.frameLength = 320
            try file.write(from: buffer)
            return url
        }

        private func waitUntil(
            timeout: Duration = testPollTimeout,
            condition: @escaping @Sendable () async -> Bool
        ) async throws {
            guard await pollUntil(timeout: timeout, condition) else {
                throw BatchSpeechTranscriberServiceTestError.timedOut
            }
        }
    }

    private enum BatchSpeechTranscriberServiceTestError: Error {
        case timedOut
    }

    private actor SequenceLanguageDetector: BatchLanguageDetecting {
        private var detections: [String]
        private(set) var audioURLs: [URL] = []
        private(set) var allowedLanguageIdentifiers: [Set<String>?] = []

        init(detections: [String]) {
            self.detections = detections
        }

        func detectLanguage(
            audioURL: URL,
            allowedLanguageIdentifiers: Set<String>?
        ) throws -> BatchLanguageDetectionOutcome {
            audioURLs.append(audioURL)
            self.allowedLanguageIdentifiers.append(allowedLanguageIdentifiers)
            guard !detections.isEmpty else { throw CocoaError(.fileReadUnknown) }
            return .confidentDetection(detections.removeFirst())
        }

        func unload() async {}
    }

    private actor CancellableLanguageDetector: BatchLanguageDetecting {
        private(set) var audioURL: URL?

        func detectLanguage(
            audioURL: URL,
            allowedLanguageIdentifiers _: Set<String>?
        ) async throws -> BatchLanguageDetectionOutcome {
            self.audioURL = audioURL
            try await Task.sleep(for: .seconds(30))
            return .confidentDetection("ja")
        }

        func unload() async {}
    }
#endif
