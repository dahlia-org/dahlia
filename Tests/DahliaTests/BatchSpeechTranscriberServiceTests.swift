@preconcurrency import AVFoundation
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchSpeechTranscriberServiceTests {
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
            #expect(recognitionCalls.map(\.audioURL) == detectedAudioURLs)
            #expect(recognitionCalls.map(\.localeIdentifier) == ["ja_JP", "en_US"])
        }

        private func request(
            audioURL: URL,
            recordedLocaleIdentifier: String,
            source: RecordingAudioSource,
            sessionID: UUID,
            recordingStart: Date,
            sessionOffsetSeconds: TimeInterval
        ) -> BatchSpeechTranscriptionRequest {
            BatchSpeechTranscriptionRequest(
                audioURL: audioURL,
                startFrame: 0,
                frameCount: 320,
                recordedLocaleIdentifiers: [recordedLocaleIdentifier],
                languageDetectionMode: .automatic,
                supportedLocales: [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")],
                source: source,
                recordingSessionId: sessionID,
                recordingStartTime: recordingStart,
                sessionOffsetSeconds: sessionOffsetSeconds
            )
        }

        private func makeAudioFile(name: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-batch-transcriber-\(name)-\(UUID.v7().uuidString).caf")
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
            buffer.frameLength = 320
            try file.write(from: buffer)
            return url
        }
    }

    private actor SequenceLanguageDetector: BatchLanguageDetecting {
        private var detections: [String]
        private(set) var audioURLs: [URL] = []

        init(detections: [String]) {
            self.detections = detections
        }

        func detectLanguage(audioURL: URL) throws -> String {
            audioURLs.append(audioURL)
            guard !detections.isEmpty else { throw CocoaError(.fileReadUnknown) }
            return detections.removeFirst()
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
#endif
