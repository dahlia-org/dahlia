@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BatchSpeechAnalyzerInputSequenceTests {
        @Test
        func readsSlicesLazilyAndAssignsOneContinuousTimeline() async throws {
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let firstURL = try makeAudioFile(name: "first", format: format, values: Array(0 ..< 200))
            let secondURL = try makeAudioFile(name: "second", format: format, values: Array(1000 ..< 1200))
            defer {
                try? FileManager.default.removeItem(at: firstURL)
                try? FileManager.default.removeItem(at: secondURL)
            }
            let readFormat = try AVAudioFile(forReading: firstURL).processingFormat
            let consumedSliceProbe = ConsumedSliceProbe()
            let consumedBufferProbe = ConsumedBufferProbe()
            let sequence = try BatchSpeechAnalyzerInputSequence(
                slices: [
                    BatchSpeechAudioSlice(audioURL: firstURL, startFrame: 40, frameCount: 80),
                    BatchSpeechAudioSlice(audioURL: secondURL, startFrame: 20, frameCount: 60),
                ],
                sourceFormat: readFormat,
                analyzerFormat: readFormat,
                onSliceConsumed: { sliceIndex in
                    await consumedSliceProbe.record(sliceIndex)
                },
                onBufferConsumed: {
                    await consumedBufferProbe.record()
                },
                converterFactory: { _, _ in PassthroughAnalyzerInputConverter() }
            )

            var iterator = sequence.makeAsyncIterator()
            let first = try #require(try await iterator.next())
            let second = try #require(try await iterator.next())
            let end = try await iterator.next()
            let firstSample = try #require(sampleValue(in: first.buffer, at: 0))
            let secondSample = try #require(sampleValue(in: second.buffer, at: 0))

            #expect(first.buffer.frameLength == 80)
            #expect(second.buffer.frameLength == 60)
            #expect(abs(firstSample - Double(40) / Double(Int16.max)) < 0.0001)
            #expect(abs(secondSample - Double(1020) / Double(Int16.max)) < 0.0001)
            #expect(first.bufferStartTime == .zero)
            #expect(second.bufferStartTime?.seconds == 0.005)
            #expect(end == nil)
            #expect(await consumedSliceProbe.sliceIndices == [0, 1])
            #expect(await consumedBufferProbe.count == 2)
        }

        @Test
        func rejectsSliceThatExtendsPastVerifiedFileLength() async throws {
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let audioURL = try makeAudioFile(name: "short", format: format, values: Array(0 ..< 80))
            defer { try? FileManager.default.removeItem(at: audioURL) }
            let readFormat = try AVAudioFile(forReading: audioURL).processingFormat
            let sequence = try BatchSpeechAnalyzerInputSequence(
                slices: [
                    BatchSpeechAudioSlice(audioURL: audioURL, startFrame: 40, frameCount: 80),
                ],
                sourceFormat: readFormat,
                analyzerFormat: readFormat,
                converterFactory: { _, _ in PassthroughAnalyzerInputConverter() }
            )
            var iterator = sequence.makeAsyncIterator()

            await #expect(throws: BatchSpeechTranscriberError.self) {
                _ = try await iterator.next()
            }
        }

        private func makeAudioFile(
            name: String,
            format: AVAudioFormat,
            values: [Int]
        ) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-batch-sequence-\(name)-\(UUID.v7().uuidString).caf")
            var file: AVAudioFile? = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: false
            )
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(values.count)
            ))
            buffer.frameLength = AVAudioFrameCount(values.count)
            let channel = try #require(buffer.int16ChannelData?[0])
            for (index, value) in values.enumerated() {
                channel[index] = Int16(value)
            }
            try file?.write(from: buffer)
            file = nil
            return url
        }

        private func sampleValue(in buffer: AVAudioPCMBuffer, at index: Int) -> Double? {
            if let channel = buffer.floatChannelData?[0] {
                return Double(channel[index])
            }
            if let channel = buffer.int16ChannelData?[0] {
                return Double(channel[index]) / Double(Int16.max)
            }
            return nil
        }
    }

    private final class PassthroughAnalyzerInputConverter: AnalyzerInputConverting {
        func convert(_ buffer: AVAudioPCMBuffer, at startTime: CMTime) -> [AnalyzerInput] {
            [AnalyzerInput(buffer: buffer, bufferStartTime: startTime)]
        }

        func finish() -> [AnalyzerInput] {
            []
        }
    }

    private actor ConsumedSliceProbe {
        private(set) var sliceIndices: [Int] = []

        func record(_ sliceIndex: Int) {
            sliceIndices.append(sliceIndex)
        }
    }

    private actor ConsumedBufferProbe {
        private(set) var count = 0

        func record() {
            count += 1
        }
    }
#endif
