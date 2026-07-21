@preconcurrency import AVFoundation
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchSpeechTranscriberServiceTests {
        @Test
        func manualModeSkipsLanguageDetectionAndUsesSelectedLocale() async throws {
            let audioURL = try makeAudioFile(name: "manual")
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let detector = SequenceLanguageDetector(detections: [])
            let recognizer = RecordingSpeechRecognizer(recognitions: [])
            let request = BatchSpeechTranscriptionRequest(
                audioURL: audioURL,
                startFrame: 0,
                frameCount: 320,
                recordedLocaleIdentifiers: ["en_GB"],
                languageDetectionMode: .manual,
                supportedLocales: [],
                source: .microphone,
                recordingSessionId: UUID.v7(),
                recordingStartTime: .now,
                sessionOffsetSeconds: 0
            )

            let result = try await BatchSpeechTranscriberService.transcribe(
                request,
                languageDetector: detector,
                speechRecognizer: recognizer
            )

            #expect(result.localeIdentifier == "en_GB")
            #expect(await detector.audioURLs.isEmpty)
            #expect(await recognizer.calls.map(\.localeIdentifier) == ["en_GB"])
        }

        @Test
        func automaticModeUsesEachCAFDetectionForLocaleTimingAndSource() async throws {
            let firstAudioURL = try makeAudioFile(name: "ja")
            let secondAudioURL = try makeAudioFile(name: "en")
            defer {
                try? FileManager.default.removeItem(at: firstAudioURL)
                try? FileManager.default.removeItem(at: secondAudioURL)
            }

            let detector = SequenceLanguageDetector(detections: [
                "ja",
                "en",
            ])
            let recognizer = RecordingSpeechRecognizer(recognitions: [
                BatchSpeechRecognition(startSeconds: 0.1, endSeconds: 0.4, text: " transcript "),
            ])
            let recordingStart = Date(timeIntervalSince1970: 1_776_384_000)
            let sessionID = UUID.v7()

            let first = try await BatchSpeechTranscriberService.transcribe(
                request(
                    audioURL: firstAudioURL,
                    recordedLocaleIdentifier: "ja_JP",
                    source: .microphone,
                    sessionID: sessionID,
                    recordingStart: recordingStart,
                    sessionOffsetSeconds: 0
                ),
                languageDetector: detector,
                speechRecognizer: recognizer
            )
            let second = try await BatchSpeechTranscriberService.transcribe(
                request(
                    audioURL: secondAudioURL,
                    recordedLocaleIdentifier: "ja_JP",
                    source: .system,
                    sessionID: sessionID,
                    recordingStart: recordingStart,
                    sessionOffsetSeconds: 30
                ),
                languageDetector: detector,
                speechRecognizer: recognizer
            )

            #expect(first.localeIdentifier == "ja_JP")
            #expect(second.localeIdentifier == "en_US")
            #expect(first.segments.first?.text == "transcript")
            #expect(first.segments.first?.speakerLabel == "mic")
            #expect(second.segments.first?.speakerLabel == "system")
            #expect(first.segments.first?.startTime == recordingStart.addingTimeInterval(0.1))
            #expect(second.segments.first?.startTime == recordingStart.addingTimeInterval(30.1))

            let detectedAudioURLs = await detector.audioURLs
            let recognitionCalls = await recognizer.calls
            #expect(detectedAudioURLs.count == 2)
            #expect(detectedAudioURLs == [firstAudioURL, secondAudioURL])
            #expect(recognitionCalls.map(\.audioURL) == detectedAudioURLs)
            #expect(recognitionCalls.map(\.localeIdentifier) == ["ja_JP", "en_US"])
        }

        @Test
        func automaticModePassesConfiguredLanguageCandidatesToDetector() async throws {
            let audioURL = try makeAudioFile(name: "candidates")
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let detector = SequenceLanguageDetector(detections: ["ja"])
            let recognizer = RecordingSpeechRecognizer(recognitions: [])
            let transcriptionRequest = request(
                audioURL: audioURL,
                recordedLocaleIdentifier: "ja_JP",
                source: .microphone,
                sessionID: UUID.v7(),
                recordingStart: .now,
                sessionOffsetSeconds: 0,
                allowedLanguageIdentifiers: ["en", "ja"]
            )

            _ = try await BatchSpeechTranscriberService.transcribe(
                transcriptionRequest,
                languageDetector: detector,
                speechRecognizer: recognizer
            )

            #expect(await detector.allowedLanguageIdentifiers == [["en", "ja"]])
        }

        @Test
        func partialRangeUsesOneTemporaryCAFAndRemovesItAfterRecognition() async throws {
            let audioURL = try makeAudioFile(name: "partial")
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let detector = SequenceLanguageDetector(detections: ["ja"])
            let recognizer = RecordingSpeechRecognizer(recognitions: [])

            _ = try await BatchSpeechTranscriberService.transcribe(
                partialRequest(audioURL: audioURL),
                languageDetector: detector,
                speechRecognizer: recognizer
            )

            let call = try #require(await recognizer.calls.first)
            #expect(await detector.audioURLs == [call.audioURL])
            #expect(call.audioURL != audioURL)
            #expect(!FileManager.default.fileExists(atPath: call.audioURL.path))
            #expect(FileManager.default.fileExists(atPath: audioURL.path))
        }

        @Test
        func cancellationRemovesPartialRangeTemporaryCAF() async throws {
            let audioURL = try makeAudioFile(name: "cancelled-partial")
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let detector = SequenceLanguageDetector(detections: ["ja"])
            let recognizer = CancellableSpeechRecognizer()
            let transcriptionTask = Task {
                try await BatchSpeechTranscriberService.transcribe(
                    partialRequest(audioURL: audioURL),
                    languageDetector: detector,
                    speechRecognizer: recognizer
                )
            }

            try await waitUntil { await recognizer.audioURL != nil }
            let temporaryURL = try #require(await recognizer.audioURL)
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
            let recognizer = RecordingSpeechRecognizer(recognitions: [])

            let result = try await BatchSpeechTranscriberService.transcribe(
                partialRequest(audioURL: audioURL),
                languageDetector: detector,
                speechRecognizer: recognizer
            )

            let temporaryURL = try #require(await detector.audioURLs.first)
            #expect(result.localeIdentifier == "en_US")
            #expect(result.languageFallback == .inferenceFailure)
            #expect(await recognizer.calls.first?.audioURL == temporaryURL)
            #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
            #expect(FileManager.default.fileExists(atPath: audioURL.path))
        }

        @Test
        func recognitionFailureRemovesPartialRangeTemporaryCAF() async throws {
            let audioURL = try makeAudioFile(name: "failed-partial-recognition")
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let detector = SequenceLanguageDetector(detections: ["ja"])
            let recognizer = FailingSpeechRecognizer()

            await #expect(throws: CocoaError.self) {
                _ = try await BatchSpeechTranscriberService.transcribe(
                    partialRequest(audioURL: audioURL),
                    languageDetector: detector,
                    speechRecognizer: recognizer
                )
            }

            let temporaryURL = try #require(await recognizer.audioURL)
            #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
            #expect(FileManager.default.fileExists(atPath: audioURL.path))
        }

        private func partialRequest(audioURL: URL) -> BatchSpeechTranscriptionRequest {
            BatchSpeechTranscriptionRequest(
                audioURL: audioURL,
                startFrame: 80,
                frameCount: 160,
                recordedLocaleIdentifiers: ["ja_JP"],
                languageDetectionMode: .automatic,
                supportedLocales: [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")],
                source: .microphone,
                recordingSessionId: UUID.v7(),
                recordingStartTime: .now,
                sessionOffsetSeconds: 0
            )
        }

        private func request(
            audioURL: URL,
            recordedLocaleIdentifier: String,
            source: RecordingAudioSource,
            sessionID: UUID,
            recordingStart: Date,
            sessionOffsetSeconds: TimeInterval,
            allowedLanguageIdentifiers: Set<String>? = nil
        ) -> BatchSpeechTranscriptionRequest {
            BatchSpeechTranscriptionRequest(
                audioURL: audioURL,
                startFrame: 0,
                frameCount: 320,
                recordedLocaleIdentifiers: [recordedLocaleIdentifier],
                languageDetectionMode: .automatic,
                supportedLocales: [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")],
                allowedLanguageIdentifiers: allowedLanguageIdentifiers,
                source: source,
                recordingSessionId: sessionID,
                recordingStartTime: recordingStart,
                sessionOffsetSeconds: sessionOffsetSeconds
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
            timeout: Duration = .seconds(5),
            condition: @escaping @Sendable () async -> Bool
        ) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while await !condition() {
                guard ContinuousClock.now < deadline else {
                    throw BatchSpeechTranscriberServiceTestError.timedOut
                }
                try await Task.sleep(for: .milliseconds(10))
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

    private actor RecordingSpeechRecognizer: BatchSpeechRecognizing {
        struct Call: Sendable {
            let audioURL: URL
            let localeIdentifier: String
        }

        private let recognitions: [BatchSpeechRecognition]
        private(set) var calls: [Call] = []

        init(recognitions: [BatchSpeechRecognition]) {
            self.recognitions = recognitions
        }

        func recognize(audioURL: URL, locale: Locale) -> [BatchSpeechRecognition] {
            calls.append(Call(audioURL: audioURL, localeIdentifier: locale.identifier))
            return recognitions
        }
    }

    private actor CancellableSpeechRecognizer: BatchSpeechRecognizing {
        private(set) var audioURL: URL?

        func recognize(audioURL: URL, locale _: Locale) async throws -> [BatchSpeechRecognition] {
            self.audioURL = audioURL
            try await Task.sleep(for: .seconds(30))
            return []
        }
    }

    private actor FailingSpeechRecognizer: BatchSpeechRecognizing {
        private(set) var audioURL: URL?

        func recognize(audioURL: URL, locale _: Locale) throws -> [BatchSpeechRecognition] {
            self.audioURL = audioURL
            throw CocoaError(.fileReadUnknown)
        }
    }
#endif
