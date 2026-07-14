@preconcurrency import AVFoundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct AudioConverterTests {
        @Test
        func downsamplingCapacityRoundsUpForFractionalOutputFrames() throws {
            let sourceFormat = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 48000,
                channels: 1,
                interleaved: false
            ))
            let targetFormat = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let input = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4096))
            input.frameLength = 4096
            let converter = try #require(AVAudioConverter(from: sourceFormat, to: targetFormat))

            let output = try #require(AudioConverter.convert(input, to: targetFormat, using: converter))

            #expect(output.frameCapacity == 1366)
        }

        @Test
        func discreteMultichannelInputIsExplicitlyMappedToMono() throws {
            let layout = try #require(AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 9
            ))
            let sourceFormat = AVAudioFormat(
                standardFormatWithSampleRate: 48000,
                channelLayout: layout
            )
            let targetFormat = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let input = try #require(AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: 4096
            ))
            input.frameLength = 4096
            let channels = try #require(input.floatChannelData)
            for channel in 0 ..< Int(sourceFormat.channelCount) {
                for frame in 0 ..< Int(input.frameLength) {
                    channels[channel][frame] = 0.1
                }
            }

            let converter = try #require(AudioConverter.makeConverter(
                from: sourceFormat,
                to: targetFormat
            ))
            let output = try #require(AudioConverter.convert(
                input,
                to: targetFormat,
                using: converter
            ))

            #expect(AudioLevelCalculator.normalizedLevel(in: output) > 0.5)
        }

        @Test
        func inferredSurroundToMonoMapIsPreserved() throws {
            let layout = try #require(AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A
            ))
            let sourceFormat = AVAudioFormat(
                standardFormatWithSampleRate: 48000,
                channelLayout: layout
            )
            let targetFormat = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))

            let converter = try #require(AudioConverter.makeConverter(
                from: sourceFormat,
                to: targetFormat
            ))

            #expect(converter.channelMap == [2])
        }
    }
#endif
