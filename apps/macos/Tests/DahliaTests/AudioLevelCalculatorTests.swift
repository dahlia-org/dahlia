import AVFoundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct AudioLevelCalculatorTests {
        @Test
        func silenceHasZeroLevel() throws {
            let buffer = try makeBuffer(sample: 0)

            #expect(AudioLevelCalculator.normalizedLevel(in: buffer) == 0)
        }

        @Test
        func audibleSamplesHavePositiveLevel() throws {
            let buffer = try makeBuffer(sample: 0.1)

            #expect(AudioLevelCalculator.normalizedLevel(in: buffer) > 0)
        }

        @Test
        func reportsEachChannelLevelSeparately() throws {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            let channels = try #require(buffer.floatChannelData)
            for frame in 0 ..< Int(buffer.frameLength) {
                channels[0][frame] = 0
                channels[1][frame] = 0.1
            }

            let levels = AudioLevelCalculator.normalizedLevels(in: buffer)

            #expect(levels.count == 2)
            #expect(levels[0] == 0)
            #expect(levels[1] > 0)
        }

        @Test
        func supportsInt16RecognitionBuffers() throws {
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            let samples = try #require(buffer.int16ChannelData?[0])
            for frame in 0 ..< Int(buffer.frameLength) {
                samples[frame] = Int16.max / 10
            }

            #expect(AudioLevelCalculator.normalizedLevel(in: buffer) > 0)
        }

        private func makeBuffer(sample: Float) throws -> AVAudioPCMBuffer {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            buffer.frameLength = 128
            let samples = try #require(buffer.floatChannelData?[0])
            for frame in 0 ..< Int(buffer.frameLength) {
                samples[frame] = sample
            }
            return buffer
        }
    }
#endif
