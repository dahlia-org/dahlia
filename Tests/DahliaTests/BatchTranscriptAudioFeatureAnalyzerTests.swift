@preconcurrency import AVFoundation
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchTranscriptAudioFeatureAnalyzerTests {
        private let analyzer = BatchTranscriptAudioFeatureAnalyzer()

        @Test
        func extractsActiveRmsPitchVoicedRatioAndPitchSpread() throws {
            let audioURL = try makeAudioFile([
                Tone(duration: 2, frequency: 220, amplitude: 0.25),
            ])
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let analysis = try analyzer.analyze(
                recognitions: [recognition(start: 0, end: 2)],
                audioURL: audioURL
            )
            let features = try firstFeatures(in: analysis)

            #expect(try abs(#require(features.activeRmsDecibels) - -15.05) < 0.5)
            #expect(try abs(#require(features.medianPitchHertz) - 220) < 3)
            #expect(features.voicedFrameRatio > 0.99)
            #expect(try #require(features.pitchSpreadHertz) < 1)
        }

        @Test
        func silenceChangesVoicedRatioWithoutDilutingActiveRms() throws {
            let continuousURL = try makeAudioFile([
                Tone(duration: 2, frequency: 220, amplitude: 0.25),
            ])
            let pausedURL = try makeAudioFile([
                Tone(duration: 1, frequency: 220, amplitude: 0.25),
                Tone(duration: 1, frequency: nil, amplitude: 0),
                Tone(duration: 1, frequency: 220, amplitude: 0.25),
            ])
            defer {
                try? FileManager.default.removeItem(at: continuousURL)
                try? FileManager.default.removeItem(at: pausedURL)
            }

            let continuous = try firstFeatures(
                in: analyzer.analyze(
                    recognitions: [recognition(start: 0, end: 2)],
                    audioURL: continuousURL
                )
            )
            let paused = try firstFeatures(
                in: analyzer.analyze(
                    recognitions: [recognition(start: 0, end: 3)],
                    audioURL: pausedURL
                )
            )

            #expect(try abs(
                #require(continuous.activeRmsDecibels)
                    - (try #require(paused.activeRmsDecibels))
            ) < 0.5)
            #expect(continuous.voicedFrameRatio > 0.99)
            #expect(paused.voicedFrameRatio > 0.6)
            #expect(paused.voicedFrameRatio < 0.72)
        }

        @Test
        func pitchSpreadCapturesVariation() throws {
            let audioURL = try makeAudioFile([
                Tone(duration: 1, frequency: 180, amplitude: 0.25),
                Tone(duration: 1, frequency: 300, amplitude: 0.25),
            ])
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let analysis = try analyzer.analyze(
                recognitions: [recognition(start: 0, end: 2)],
                audioURL: audioURL
            )
            let features = try firstFeatures(in: analysis)

            #expect(try #require(features.pitchSpreadHertz) > 100)
        }

        @Test
        func highFrequencySignalDoesNotAliasIntoPitchRange() throws {
            let audioURL = try makeAudioFile([
                Tone(duration: 2, frequency: 7800, amplitude: 0.25),
            ])
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let features = try firstFeatures(
                in: analyzer.analyze(
                    recognitions: [recognition(start: 0, end: 2)],
                    audioURL: audioURL
                )
            )

            #expect(features.activeRmsDecibels != nil)
            #expect(features.voicedFrameRatio > 0.99)
            #expect(features.medianPitchHertz == nil)
            #expect(features.pitchSpreadHertz == nil)
        }

        @Test(arguments: [60.0, 500.0])
        func pitchRangeBoundariesRemainDetectable(frequency: Double) throws {
            let audioURL = try makeAudioFile([
                Tone(duration: 2, frequency: frequency, amplitude: 0.25),
            ])
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let features = try firstFeatures(
                in: analyzer.analyze(
                    recognitions: [recognition(start: 0, end: 2)],
                    audioURL: audioURL
                )
            )

            #expect(try abs(#require(features.medianPitchHertz) - frequency) < 3)
        }

        @Test
        func segmentFeaturesExcludeAdjacentAudio() throws {
            let audioURL = try makeAudioFile([
                Tone(duration: 1, frequency: 220, amplitude: 0.25),
                Tone(duration: 1, frequency: nil, amplitude: 0),
            ])
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let features = try firstFeatures(
                in: analyzer.analyze(
                    recognitions: [recognition(start: 1, end: 1.01)],
                    audioURL: audioURL
                )
            )

            #expect(features.activeRmsDecibels == nil)
            #expect(features.medianPitchHertz == nil)
            #expect(features.voicedFrameRatio == 0)
            #expect(features.pitchSpreadHertz == nil)
        }

        @Test
        func silenceAndShortAudioUseDefinedMissingValues() throws {
            let silenceURL = try makeAudioFile([
                Tone(duration: 1, frequency: nil, amplitude: 0),
            ])
            let shortURL = try makeAudioFile([
                Tone(duration: 0.01, frequency: 220, amplitude: 0.25),
            ])
            defer {
                try? FileManager.default.removeItem(at: silenceURL)
                try? FileManager.default.removeItem(at: shortURL)
            }

            let silence = try firstFeatures(
                in: analyzer.analyze(
                    recognitions: [recognition(start: 0, end: 1)],
                    audioURL: silenceURL
                )
            )
            let short = try firstFeatures(
                in: analyzer.analyze(
                    recognitions: [recognition(start: 0, end: 0.01)],
                    audioURL: shortURL
                )
            )

            #expect(silence.activeRmsDecibels == nil)
            #expect(silence.medianPitchHertz == nil)
            #expect(silence.voicedFrameRatio == 0)
            #expect(silence.pitchSpreadHertz == nil)
            #expect(short.activeRmsDecibels != nil)
            #expect(short.medianPitchHertz == nil)
            #expect(short.voicedFrameRatio == 1)
            #expect(short.pitchSpreadHertz == nil)
        }

        @Test
        func manualSlicesFormOneLogicalAudioTimeline() async throws {
            let firstURL = try makeAudioFile([
                Tone(duration: 1, frequency: 220, amplitude: 0.25),
            ])
            let secondURL = try makeAudioFile([
                Tone(duration: 1, frequency: 220, amplitude: 0.25),
            ])
            defer {
                try? FileManager.default.removeItem(at: firstURL)
                try? FileManager.default.removeItem(at: secondURL)
            }
            let slices = [
                BatchSpeechAudioSlice(audioURL: firstURL, startFrame: 0, frameCount: 16000),
                BatchSpeechAudioSlice(audioURL: secondURL, startFrame: 0, frameCount: 16000),
            ]
            let run = BatchTranscriptionRun(
                slices: slices,
                sliceFileIndices: [0, 1],
                localeIdentifier: "en_US",
                source: .microphone,
                recordingSessionId: .v7(),
                recordingStartTime: Date(timeIntervalSince1970: 1_776_384_000),
                sessionOffsetSeconds: 0,
                fileIndices: [0, 1]
            )
            let recognizer = SliceSpeechRecognizer(
                recognitions: [recognition(start: 0.8, end: 1.2)]
            )

            let result = try await BatchTranscriptionRunService.transcribe(
                run,
                speechRecognizer: recognizer
            )
            let features = try #require(result.segments.first?.audioFeatures)

            #expect(try abs(#require(features.medianPitchHertz) - 220) < 3)
            #expect(features.voicedFrameRatio > 0.99)
        }

        @Test
        func extractionFailureDoesNotFailTranscriptionRun() async throws {
            let audioURL = try makeAudioFile([
                Tone(duration: 1, frequency: 220, amplitude: 0.25),
            ])
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let run = BatchTranscriptionRun(
                slices: [BatchSpeechAudioSlice(audioURL: audioURL, startFrame: 0, frameCount: 16000)],
                sliceFileIndices: [0],
                localeIdentifier: "en_US",
                source: .microphone,
                recordingSessionId: .v7(),
                recordingStartTime: .now,
                sessionOffsetSeconds: 0,
                fileIndices: [0]
            )

            let result = try await BatchTranscriptionRunService.transcribe(
                run,
                speechRecognizer: SliceSpeechRecognizer(
                    recognitions: [recognition(start: 0.2, end: 0.8)]
                ),
                audioFeatureAnalyzer: FailingAudioFeatureAnalyzer()
            )

            #expect(result.segments.map(\.text) == ["speech"])
            #expect(result.segments.first?.audioFeatures == nil)
        }

        @Test
        func invalidRecognitionOnlyOmitsThatSegmentsFeatures() throws {
            let audioURL = try makeAudioFile([
                Tone(duration: 1, frequency: 220, amplitude: 0.25),
            ])
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let analysis = try analyzer.analyze(
                recognitions: [
                    recognition(start: 0.1, end: 0.5),
                    recognition(start: 0.1, end: 1.000_062_5),
                    recognition(start: 2, end: 3),
                    recognition(start: 0.1, end: .greatestFiniteMagnitude),
                ],
                audioURL: audioURL
            )

            #expect(analysis.features[0] != nil)
            #expect(analysis.features[1] == nil)
            #expect(analysis.features[2] == nil)
            #expect(analysis.features[3] == nil)
            #expect(analysis.invalidRecognitionCount == 3)
        }

        private func recognition(start: TimeInterval, end: TimeInterval) -> BatchSpeechRecognition {
            BatchSpeechRecognition(startSeconds: start, endSeconds: end, text: "speech")
        }

        private func firstFeatures(
            in analysis: BatchTranscriptAudioFeatureAnalysis
        ) throws -> TranscriptAudioFeatures {
            let first = try #require(analysis.features.first)
            return try #require(first)
        }

        private func makeAudioFile(_ tones: [Tone]) throws -> URL {
            let sampleRate = 16000.0
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ))
            let url = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-audio-features-\(UUID.v7().uuidString).caf")
            let audioFile = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let frameCount = tones.reduce(0) {
                $0 + Int(($1.duration * sampleRate).rounded())
            }
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ))
            buffer.frameLength = AVAudioFrameCount(frameCount)
            let samples = try #require(buffer.floatChannelData?[0])
            var frame = 0
            for tone in tones {
                let toneFrameCount = Int((tone.duration * sampleRate).rounded())
                for toneFrame in 0 ..< toneFrameCount {
                    if let frequency = tone.frequency {
                        samples[frame] = tone.amplitude * sin(
                            2 * .pi * Float(frequency) * Float(toneFrame) / Float(sampleRate)
                        )
                    } else {
                        samples[frame] = 0
                    }
                    frame += 1
                }
            }
            try audioFile.write(from: buffer)
            return url
        }
    }

    private struct Tone {
        let duration: TimeInterval
        let frequency: Double?
        let amplitude: Float
    }

    private struct SliceSpeechRecognizer: BatchSpeechRecognizing {
        let recognitions: [BatchSpeechRecognition]

        func recognize(audioURL _: URL, locale _: Locale) -> [BatchSpeechRecognition] {
            []
        }

        func recognize(
            audioSlices _: [BatchSpeechAudioSlice],
            locale _: Locale
        ) -> [BatchSpeechRecognition] {
            recognitions
        }
    }

    private struct FailingAudioFeatureAnalyzer: BatchTranscriptAudioFeatureAnalyzing {
        func analyze(
            recognitions _: [BatchSpeechRecognition],
            audioURL _: URL
        ) throws -> BatchTranscriptAudioFeatureAnalysis {
            throw CocoaError(.fileReadUnknown)
        }

        func analyze(
            recognitions _: [BatchSpeechRecognition],
            audioSlices _: [BatchSpeechAudioSlice]
        ) throws -> BatchTranscriptAudioFeatureAnalysis {
            throw CocoaError(.fileReadUnknown)
        }
    }
#endif
