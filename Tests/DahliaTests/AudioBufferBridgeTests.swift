@preconcurrency import AVFoundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct AudioBufferBridgeTests {
        @Test
        func conversionIsHiddenBehindReplaceableAnalyzerInputBoundary() async throws {
            let sourceFormat = try #require(AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 48000,
                channels: 1,
                interleaved: false
            ))
            let analyzerFormat = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let inputBuffer = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 480))
            inputBuffer.frameLength = 480
            let converter = FakeAnalyzerInputConverter(outputFormat: analyzerFormat)
            let bridge = try AudioBufferBridge(
                sourceFormat: sourceFormat,
                analyzerFormat: analyzerFormat,
                inputConverter: converter
            )
            let chunk = CapturedAudioChunk(
                source: .microphone,
                buffer: inputBuffer,
                sessionRelativeStartTime: CMTime(seconds: 12.5, preferredTimescale: 48000)
            )

            #expect(bridge.append(chunk))
            bridge.finish()
            var iterator = bridge.stream.makeAsyncIterator()
            let convertedInput = await iterator.next()

            #expect(converter.conversionCount == 1)
            #expect(convertedInput?.buffer.format == analyzerFormat)
            #expect(convertedInput?.bufferStartTime?.seconds == 12.5)
        }

        @Test
        func appendReportsTerminatedStream() throws {
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
            buffer.frameLength = 16
            let bridge = try AudioBufferBridge(sourceFormat: format, analyzerFormat: format)
            let chunk = CapturedAudioChunk(
                source: .system,
                buffer: buffer,
                sessionRelativeStartTime: .zero
            )

            bridge.finish()

            #expect(!bridge.append(chunk))
        }
    }
#endif
