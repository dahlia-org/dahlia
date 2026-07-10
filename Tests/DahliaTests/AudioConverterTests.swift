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
    }
#endif
