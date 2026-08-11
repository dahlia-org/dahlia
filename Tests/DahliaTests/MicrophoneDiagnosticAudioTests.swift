@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MicrophoneDiagnosticAudioTests {
        @Test
        func echoCancellationDecisionAlwaysEnablesBuiltInMicrophone() {
            #expect(MicrophoneEchoCancellationDecision.isEnabled(
                activeDeviceID: 42,
                forcesEchoCancellationForExternalMicrophone: false,
                isBuiltInDevice: { $0 == 42 }
            ))
            #expect(MicrophoneEchoCancellationDecision.isEnabled(
                activeDeviceID: 42,
                forcesEchoCancellationForExternalMicrophone: true,
                isBuiltInDevice: { $0 == 42 }
            ))
        }

        @Test
        func echoCancellationDecisionResolvesExplicitAndSystemDefaultDevices() {
            #expect(MicrophoneEchoCancellationDecision.resolveActiveDeviceID(
                selectedDeviceID: 42,
                defaultDeviceID: 7
            ) == 42)
            #expect(MicrophoneEchoCancellationDecision.resolveActiveDeviceID(
                selectedDeviceID: nil,
                defaultDeviceID: 7
            ) == 7)
        }

        @Test(arguments: [false, true])
        func echoCancellationDecisionUsesToggleForExternalMicrophone(toggle: Bool) {
            #expect(MicrophoneEchoCancellationDecision.isEnabled(
                activeDeviceID: 42,
                forcesEchoCancellationForExternalMicrophone: toggle,
                isBuiltInDevice: { _ in false }
            ) == toggle)
        }

        @Test(arguments: [false, true])
        func echoCancellationDecisionTreatsMissingDeviceAsExternal(toggle: Bool) {
            #expect(MicrophoneEchoCancellationDecision.isEnabled(
                activeDeviceID: nil,
                forcesEchoCancellationForExternalMicrophone: toggle,
                isBuiltInDevice: { _ in true }
            ) == toggle)
        }

        @Test
        func rawBufferProcessorRoutesMicrophoneFramesDirectly() throws {
            let format = try makeFloatFormat()
            let processor = try MicrophoneCaptureBufferProcessor(
                targetFormat: format,
                usesEchoCancellation: false
            )
            let output = OSAllocatedUnfairLock(initialState: OutputObservation())
            processor.onOutputBuffer = { buffer in
                let identity = ObjectIdentifier(buffer)
                let frameCount = Int(buffer.frameLength)
                output.withLock {
                    $0.identities.append(identity)
                    $0.frameCount += frameCount
                }
            }
            let input = try makeBuffer(format: format, frameCount: 257)

            processor.acceptMicrophone(makeAudio(input, presentationTime: 10))
            try processor.finish()

            let delivered = output.withLock { $0 }
            #expect(delivered.identities == [ObjectIdentifier(input)])
            #expect(delivered.frameCount == 257)
        }

        @Test
        func echoCancellationPassesUnreferencedFramesThroughAfterMaximumHold() throws {
            let format = try makeFloatFormat()
            let processor = try MicrophoneCaptureBufferProcessor(
                targetFormat: format,
                usesEchoCancellation: true
            )
            let output = OSAllocatedUnfairLock(initialState: OutputObservation())
            let processedFrameCount = OSAllocatedUnfairLock(initialState: 0)
            processor.onOutputBuffer = { buffer in
                let identity = ObjectIdentifier(buffer)
                let frameCount = Int(buffer.frameLength)
                output.withLock {
                    $0.identities.append(identity)
                    $0.frameCount += frameCount
                }
            }
            processor.onProcessedBuffer = { buffer in
                processedFrameCount.withLock { $0 += Int(buffer.frameLength) }
            }
            let first = try makeBuffer(format: format, frameCount: 160)
            let second = try makeBuffer(format: format, frameCount: 160)

            processor.acceptMicrophone(makeAudio(first, presentationTime: 10))
            processor.acceptMicrophone(makeAudio(second, presentationTime: 10.11))
            try processor.finish()

            #expect(output.withLock { $0.frameCount } == 320)
            #expect(processedFrameCount.withLock { $0 } == 0)
        }

        @Test
        func echoCancellationFlushesOlderRemainderBeforeUnreferencedAudio() throws {
            let format = try makeFloatFormat()
            let fake = BufferingEchoCancellationProcessor(format: format)
            let processor = try MicrophoneCaptureBufferProcessor(
                targetFormat: format,
                usesEchoCancellation: true,
                makeEchoCancellationProcessor: { fake }
            )
            let observedSamples = OSAllocatedUnfairLock(initialState: [Float]())
            let processedSamples = OSAllocatedUnfairLock(initialState: [Float]())
            processor.onOutputBuffer = { buffer in
                guard let samples = buffer.floatChannelData?[0] else { return }
                let copiedSamples = Array(UnsafeBufferPointer(
                    start: samples,
                    count: Int(buffer.frameLength)
                ))
                observedSamples.withLock {
                    $0.append(contentsOf: copiedSamples)
                }
            }
            processor.onProcessedBuffer = { buffer in
                guard let samples = buffer.floatChannelData?[0] else { return }
                let copiedSamples = Array(UnsafeBufferPointer(
                    start: samples,
                    count: Int(buffer.frameLength)
                ))
                processedSamples.withLock {
                    $0.append(contentsOf: copiedSamples)
                }
            }

            let firstReference = try makeConstantBuffer(format: format, frameCount: 160, value: 0)
            let firstCapture = try makeConstantBuffer(format: format, frameCount: 100, value: 0.1)
            let unreferencedCapture = try makeConstantBuffer(format: format, frameCount: 100, value: 0.2)
            let finalCapture = try makeConstantBuffer(format: format, frameCount: 100, value: 0.3)
            let finalReference = try makeConstantBuffer(format: format, frameCount: 160, value: 0)

            processor.acceptSystemAudio(makeAudio(firstReference, presentationTime: 10))
            processor.acceptMicrophone(makeAudio(firstCapture, presentationTime: 10))
            processor.acceptMicrophone(makeAudio(unreferencedCapture, presentationTime: 10.2))
            processor.acceptMicrophone(makeAudio(finalCapture, presentationTime: 10.31))
            processor.acceptSystemAudio(makeAudio(finalReference, presentationTime: 10.31))
            try processor.finish()

            let samples = observedSamples.withLock { $0 }
            #expect(samples.count == 300)
            #expect(samples[0 ..< 100].allSatisfy { $0 == 0.1 })
            #expect(samples[100 ..< 200].allSatisfy { $0 == 0.2 })
            #expect(samples[200 ..< 300].allSatisfy { $0 == 0.3 })
            let processed = processedSamples.withLock { $0 }
            #expect(processed.count == 200)
            #expect(processed[0 ..< 100].allSatisfy { $0 == 0.1 })
            #expect(processed[100 ..< 200].allSatisfy { $0 == 0.3 })
        }

        @Test
        func echoCancellationRuntimeFailurePassesCurrentCaptureThroughAndWarnsOnce() throws {
            let format = try makeFloatFormat()
            let fake = FailingEchoCancellationProcessor(format: format)
            let processor = try MicrophoneCaptureBufferProcessor(
                targetFormat: format,
                usesEchoCancellation: true,
                makeEchoCancellationProcessor: { fake }
            )
            let output = OSAllocatedUnfairLock(initialState: OutputObservation())
            let processedFrameCount = OSAllocatedUnfairLock(initialState: 0)
            let bypassCount = OSAllocatedUnfairLock(initialState: 0)
            processor.onOutputBuffer = { buffer in
                let identity = ObjectIdentifier(buffer)
                let frameCount = Int(buffer.frameLength)
                output.withLock {
                    $0.identities.append(identity)
                    $0.frameCount += frameCount
                }
            }
            processor.onProcessedBuffer = { buffer in
                processedFrameCount.withLock { $0 += Int(buffer.frameLength) }
            }
            processor.onEchoCancellationBypassed = { _ in
                bypassCount.withLock { $0 += 1 }
            }
            let reference = try makeBuffer(format: format, frameCount: 160)
            let capture = try makeBuffer(format: format, frameCount: 160)

            processor.acceptSystemAudio(makeAudio(reference, presentationTime: 10))
            processor.acceptMicrophone(makeAudio(capture, presentationTime: 10))
            processor.acceptMicrophone(makeAudio(capture, presentationTime: 10.01))
            try processor.finish()

            #expect(output.withLock { $0.identities.count } == 2)
            #expect(output.withLock { $0.identities.first } == ObjectIdentifier(capture))
            #expect(output.withLock { $0.frameCount } == 320)
            #expect(processedFrameCount.withLock { $0 } == 160)
            #expect(bypassCount.withLock { $0 } == 1)
        }

        @Test
        func echoCancellationPreservesCaptureFramesAcrossArbitraryBufferSizes() throws {
            let processor = try WebRTCAEC3Processor()
            let firstRender = try makeBuffer(format: processor.format, frameCount: 257)
            let secondRender = try makeBuffer(format: processor.format, frameCount: 777)
            let firstCapture = try makeBuffer(format: processor.format, frameCount: 431)
            let secondCapture = try makeBuffer(format: processor.format, frameCount: 1_337)

            try processor.processRender(firstRender)
            try processor.processRender(secondRender)
            var output: [AVAudioPCMBuffer] = []
            try processor.processCapture(firstCapture) { output.append($0) }
            try processor.processCapture(secondCapture) { output.append($0) }
            try processor.finish { output.append($0) }

            #expect(processor.format.sampleRate == 16_000)
            #expect(processor.latency == 0.01)
            #expect(output.reduce(0) { $0 + Int($1.frameLength) } == 1_768)
            #expect(output.allSatisfy { $0.format == processor.format })
            #expect(output.allSatisfy { buffer in
                guard let samples = buffer.floatChannelData?[0] else { return false }
                return (0 ..< Int(buffer.frameLength)).allSatisfy { samples[$0].isFinite }
            })
        }

        @Test
        func echoCancellationAttenuatesDelayedRenderSignalAfterConvergence() throws {
            let processor = try WebRTCAEC3Processor()
            let frameCount = 1_000
            let delayFrames = 8
            var renderHistory = Array(
                repeating: [Float](repeating: 0, count: 160),
                count: delayFrames + 1
            )
            var randomState: UInt32 = 0x1234_5678
            var inputEnergy = 0.0
            var outputEnergy = 0.0

            for frameIndex in 0 ..< frameCount {
                let renderBuffer = try makeBuffer(format: processor.format, frameCount: 160)
                let renderSamples = try #require(renderBuffer.floatChannelData?[0])
                for sampleIndex in 0 ..< 160 {
                    randomState = randomState &* 1_664_525 &+ 1_013_904_223
                    renderSamples[sampleIndex] = (
                        Float(randomState >> 8) / 8_388_607.5 - 1
                    ) * 0.2
                }
                renderHistory[frameIndex % renderHistory.count] = Array(
                    UnsafeBufferPointer(start: renderSamples, count: 160)
                )

                let captureBuffer = try makeBuffer(format: processor.format, frameCount: 160)
                let captureSamples = try #require(captureBuffer.floatChannelData?[0])
                let delayedRender = renderHistory[(frameIndex + 1) % renderHistory.count]
                for sampleIndex in 0 ..< 160 {
                    captureSamples[sampleIndex] = delayedRender[sampleIndex] * 0.35
                }

                try processor.processRender(renderBuffer)
                var processedBuffers: [AVAudioPCMBuffer] = []
                try processor.processCapture(captureBuffer) { processedBuffers.append($0) }
                let output = try #require(processedBuffers.first)
                if frameIndex >= frameCount - 250 {
                    let outputSamples = try #require(output.floatChannelData?[0])
                    for sampleIndex in 0 ..< 160 {
                        inputEnergy += Double(captureSamples[sampleIndex] * captureSamples[sampleIndex])
                        outputEnergy += Double(outputSamples[sampleIndex] * outputSamples[sampleIndex])
                    }
                }
            }

            #expect(sqrt(outputEnergy / inputEnergy) < 0.5)
        }

        @Test
        func diagnosticWriterFinalizesRawReferenceAndProcessedCAF() async throws {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "MicrophoneDiagnosticAudioTests-\(UUID.v7())", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: root) }

            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48000,
                channels: 1,
                interleaved: false
            ))
            let writer = try MicrophoneDiagnosticAudioWriter(
                rawFormat: format,
                processedFormat: format,
                referenceFormat: format,
                rootDirectory: root
            )
            let buffer = try makeBuffer(format: format, frameCount: 256)

            writer.appendRaw(buffer)
            writer.appendReference(buffer)
            writer.appendProcessed(buffer)
            await writer.finish()

            let rawURL = try #require(writer.rawAudioURL)
            let referenceURL = try #require(writer.referenceAudioURL)
            let processedURL = try #require(writer.processedAudioURL)
            #expect(try AVAudioFile(forReading: rawURL).length == 256)
            #expect(try AVAudioFile(forReading: referenceURL).length == 256)
            #expect(try AVAudioFile(forReading: processedURL).length == 256)
        }

        @Test
        func echoCancellationReportsReferenceAndCaptureTiming() throws {
            let processor = try WebRTCAEC3Processor()
            let render = try makeBuffer(format: processor.format, frameCount: 160)
            let capture = try makeBuffer(format: processor.format, frameCount: 160)
            let renderReceived = CMClockGetTime(CMClockGetHostTimeClock())
            let renderPTS = renderReceived - CMTime(seconds: 0.02, preferredTimescale: 1_000_000)

            try processor.processRender(
                render,
                presentationTimeStamp: renderPTS,
                receivedHostTime: renderReceived
            )
            let captureReceived = CMClockGetTime(CMClockGetHostTimeClock())
            let capturePTS = captureReceived - CMTime(seconds: 0.03, preferredTimescale: 1_000_000)
            try processor.processCapture(
                capture,
                presentationTimeStamp: capturePTS,
                receivedHostTime: captureReceived,
                referenceWasReady: true,
                onOutput: { _ in }
            )
            let statistics = processor.statistics()

            #expect(statistics.referenceBufferCount == 1)
            #expect(statistics.referenceFrameCount == 160)
            #expect(statistics.captureBufferCount == 1)
            #expect(statistics.captureFrameCount == 160)
            #expect(statistics.captureWithoutReferenceFrameCount == 0)
            #expect(statistics.streamDelayHintMilliseconds != nil)
            #expect(statistics.presentationTimeDeltaMilliseconds != nil)
            #expect(statistics.referenceCallbackLatencyMilliseconds != nil)
            #expect(statistics.captureCallbackLatencyMilliseconds != nil)
            #expect(statistics.renderFrameLeadMilliseconds == 0)
        }

        @Test
        func echoCaptureAlignmentWaitsForReferenceOrMaximumHold() {
            let capturePTS = CMTime(seconds: 10, preferredTimescale: 1_000)

            #expect(!EchoCaptureAlignment.referenceCoversCapture(
                referenceEnd: CMTime(seconds: 9.99, preferredTimescale: 1_000),
                capturePresentationTimeStamp: capturePTS
            ))
            #expect(EchoCaptureAlignment.referenceCoversCapture(
                referenceEnd: CMTime(seconds: 10.01, preferredTimescale: 1_000),
                capturePresentationTimeStamp: capturePTS
            ))
            #expect(!EchoCaptureAlignment.holdExpired(
                oldestCapturePresentationTimeStamp: capturePTS,
                latestCapturePresentationTimeStamp: CMTime(seconds: 10.09, preferredTimescale: 1_000),
                maximumHold: 0.1
            ))
            #expect(EchoCaptureAlignment.holdExpired(
                oldestCapturePresentationTimeStamp: capturePTS,
                latestCapturePresentationTimeStamp: CMTime(seconds: 10.1, preferredTimescale: 1_000),
                maximumHold: 0.1
            ))
        }

        private func makeBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            guard let samples = buffer.floatChannelData?[0] else {
                Issue.record("Expected non-interleaved Float32 audio")
                return buffer
            }
            for frame in 0 ..< Int(frameCount) {
                samples[frame] = sin(Float(frame) * 0.03) * 0.1
            }
            return buffer
        }

        private func makeFloatFormat() throws -> AVAudioFormat {
            try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
        }

        private func makeConstantBuffer(
            format: AVAudioFormat,
            frameCount: AVAudioFrameCount,
            value: Float
        ) throws -> AVAudioPCMBuffer {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let samples = try #require(buffer.floatChannelData?[0])
            samples.update(repeating: value, count: Int(frameCount))
            return buffer
        }

        private func makeAudio(
            _ buffer: AVAudioPCMBuffer,
            presentationTime: TimeInterval
        ) -> ScreenCaptureAudioBuffer {
            ScreenCaptureAudioBuffer(
                buffer: buffer,
                presentationTimeStamp: CMTime(seconds: presentationTime, preferredTimescale: 1_000_000),
                receivedHostTime: .zero
            )
        }
    }

    private struct OutputObservation: Sendable {
        var identities: [ObjectIdentifier] = []
        var frameCount = 0
    }

    private final class FailingEchoCancellationProcessor: EchoCancellationProcessing {
        let format: AVAudioFormat
        let latency = 0.01

        init(format: AVAudioFormat) {
            self.format = format
        }

        func processRender(
            _: AVAudioPCMBuffer,
            presentationTimeStamp _: CMTime?,
            receivedHostTime _: CMTime?
        ) throws {}

        func processCapture(
            _ buffer: AVAudioPCMBuffer,
            presentationTimeStamp _: CMTime?,
            receivedHostTime _: CMTime?,
            referenceWasReady _: Bool?,
            onOutput: (AVAudioPCMBuffer) -> Void
        ) throws {
            onOutput(buffer)
            throw Failure.expected
        }

        func flushCaptureRemainder(onOutput _: (AVAudioPCMBuffer) -> Void) throws {}

        func finish(onOutput _: (AVAudioPCMBuffer) -> Void) throws {}

        func statistics() -> WebRTCAEC3Statistics {
            WebRTCAEC3Statistics(
                echoReturnLossEnhancement: nil,
                delayMilliseconds: nil,
                residualEchoLikelihood: nil,
                referenceBufferCount: 0,
                referenceFrameCount: 0,
                captureBufferCount: 0,
                captureFrameCount: 0,
                captureWithoutReferenceFrameCount: 0,
                streamDelayHintMilliseconds: nil,
                presentationTimeDeltaMilliseconds: nil,
                referenceCallbackLatencyMilliseconds: nil,
                captureCallbackLatencyMilliseconds: nil,
                renderFrameLeadMilliseconds: 0
            )
        }

        private enum Failure: Error {
            case expected
        }
    }

    private final class BufferingEchoCancellationProcessor: EchoCancellationProcessing {
        let format: AVAudioFormat
        let latency = 0.01
        private var pending: [AVAudioPCMBuffer] = []

        init(format: AVAudioFormat) {
            self.format = format
        }

        func processRender(
            _: AVAudioPCMBuffer,
            presentationTimeStamp _: CMTime?,
            receivedHostTime _: CMTime?
        ) throws {}

        func processCapture(
            _ buffer: AVAudioPCMBuffer,
            presentationTimeStamp _: CMTime?,
            receivedHostTime _: CMTime?,
            referenceWasReady _: Bool?,
            onOutput _: (AVAudioPCMBuffer) -> Void
        ) throws {
            pending.append(buffer)
        }

        func flushCaptureRemainder(onOutput: (AVAudioPCMBuffer) -> Void) throws {
            pending.forEach(onOutput)
            pending.removeAll()
        }

        func finish(onOutput: (AVAudioPCMBuffer) -> Void) throws {
            try flushCaptureRemainder(onOutput: onOutput)
        }

        func statistics() -> WebRTCAEC3Statistics {
            WebRTCAEC3Statistics(
                echoReturnLossEnhancement: nil,
                delayMilliseconds: nil,
                residualEchoLikelihood: nil,
                referenceBufferCount: 0,
                referenceFrameCount: 0,
                captureBufferCount: 0,
                captureFrameCount: 0,
                captureWithoutReferenceFrameCount: 0,
                streamDelayHintMilliseconds: nil,
                presentationTimeDeltaMilliseconds: nil,
                referenceCallbackLatencyMilliseconds: nil,
                captureCallbackLatencyMilliseconds: nil,
                renderFrameLeadMilliseconds: 0
            )
        }
    }
#endif
