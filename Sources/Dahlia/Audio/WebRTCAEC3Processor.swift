@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import DahliaAEC3

struct WebRTCAEC3Statistics: Sendable, Equatable {
    let echoReturnLossEnhancement: Double?
    let delayMilliseconds: Int?
    let residualEchoLikelihood: Double?
    let referenceBufferCount: Int
    let referenceFrameCount: Int64
    let captureBufferCount: Int
    let captureFrameCount: Int64
    let captureWithoutReferenceFrameCount: Int64
    let streamDelayHintMilliseconds: Int?
    let presentationTimeDeltaMilliseconds: Double?
    let referenceCallbackLatencyMilliseconds: Double?
    let captureCallbackLatencyMilliseconds: Double?
    let renderFrameLeadMilliseconds: Double
}

/// ScreenCaptureKit から届く system audio を far-end 参照として AEC3 に渡し、
/// 同じ形式の microphone PCM からスピーカー回り込みを除去する。
/// 呼び出し元は両ストリームを同じ serial queue 上で供給する。
final class WebRTCAEC3Processor: EchoCancellationProcessing, @unchecked Sendable {
    static let sampleRate: Double = 16000

    let format: AVAudioFormat
    let latency: TimeInterval

    private let processor: OpaquePointer
    private let frameSize: Int
    private var renderSamples = PendingFloatSamples()
    private var captureSamples = PendingFloatSamples()
    private var timing = TimingState()

    init() throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let processor = dahlia_aec3_create(Int32(Self.sampleRate)) else {
            throw AudioCaptureError.echoCancellationUnavailable
        }
        let frameSize = Int(dahlia_aec3_frame_size(processor))
        guard frameSize > 0 else {
            dahlia_aec3_destroy(processor)
            throw AudioCaptureError.echoCancellationUnavailable
        }
        self.format = format
        self.processor = processor
        self.frameSize = frameSize
        latency = Double(frameSize) / Self.sampleRate
    }

    deinit {
        dahlia_aec3_destroy(processor)
    }

    func processRender(
        _ buffer: AVAudioPCMBuffer,
        presentationTimeStamp: CMTime? = nil,
        receivedHostTime: CMTime? = nil
    ) throws {
        try validate(buffer)
        timing.referenceBufferCount += 1
        timing.referenceFrameCount += Int64(buffer.frameLength)
        timing.latestReferencePresentationTimeStamp = presentationTimeStamp
        timing.latestReferenceReceivedHostTime = receivedHostTime
        timing.latestReferenceProcessedHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        timing.referenceCallbackLatencyMilliseconds = Self.milliseconds(
            from: presentationTimeStamp,
            to: receivedHostTime
        )
        renderSamples.append(buffer)
        while let frame = renderSamples.take(frameSize) {
            let status = frame.withUnsafeBufferPointer { samples in
                dahlia_aec3_process_render(processor, samples.baseAddress, samples.count)
            }
            guard status == 0 else {
                throw AudioCaptureError.echoCancellationUnavailable
            }
            timing.processedReferenceFrameCount += Int64(frameSize)
        }
    }

    func processCapture(
        _ buffer: AVAudioPCMBuffer,
        presentationTimeStamp: CMTime? = nil,
        receivedHostTime: CMTime? = nil,
        referenceWasReady: Bool? = nil,
        onOutput: (AVAudioPCMBuffer) -> Void
    ) throws {
        do {
            try validate(buffer)
        } catch {
            onOutput(buffer)
            throw error
        }
        timing.captureBufferCount += 1
        timing.captureFrameCount += Int64(buffer.frameLength)
        timing.currentCaptureHasAlignedReference = referenceWasReady
            ?? (timing.processedReferenceFrameCount > 0)
        timing.captureCallbackLatencyMilliseconds = Self.milliseconds(
            from: presentationTimeStamp,
            to: receivedHostTime
        )
        updateStreamDelay(
            capturePresentationTimeStamp: presentationTimeStamp
        )
        captureSamples.append(buffer)
        try drainCompleteCaptureFrames(onOutput: onOutput)
    }

    func flushCaptureRemainder(onOutput: (AVAudioPCMBuffer) -> Void) throws {
        let frameCount = captureSamples.count
        guard let samples = captureSamples.peek(frameCount) else { return }
        let buffer = try makeBuffer(samples: samples)
        captureSamples.discard(frameCount)
        onOutput(buffer)
    }

    func finish(onOutput: (AVAudioPCMBuffer) -> Void) throws {
        try drainCompleteCaptureFrames(onOutput: onOutput)
        let remainingCount = captureSamples.count
        guard remainingCount > 0, var frame = captureSamples.take(remainingCount) else {
            return
        }
        frame.append(contentsOf: repeatElement(0, count: frameSize - remainingCount))
        do {
            try onOutput(processCaptureFrame(frame, outputFrameCount: remainingCount))
        } catch {
            try onOutput(makeBuffer(samples: Array(frame.prefix(remainingCount))))
            throw error
        }
    }

    func statistics() -> WebRTCAEC3Statistics {
        let statistics = dahlia_aec3_get_statistics(processor)
        let renderFrameLeadMilliseconds = Double(
            timing.processedReferenceFrameCount - timing.processedCaptureFrameCount
        ) / Self.sampleRate * 1000
        return WebRTCAEC3Statistics(
            echoReturnLossEnhancement: statistics.has_echo_return_loss_enhancement
                ? statistics.echo_return_loss_enhancement : nil,
            delayMilliseconds: statistics.has_delay_ms ? Int(statistics.delay_ms) : nil,
            residualEchoLikelihood: statistics.has_residual_echo_likelihood
                ? statistics.residual_echo_likelihood : nil,
            referenceBufferCount: timing.referenceBufferCount,
            referenceFrameCount: timing.referenceFrameCount,
            captureBufferCount: timing.captureBufferCount,
            captureFrameCount: timing.captureFrameCount,
            captureWithoutReferenceFrameCount: timing.captureWithoutReferenceFrameCount,
            streamDelayHintMilliseconds: timing.streamDelayHintMilliseconds,
            presentationTimeDeltaMilliseconds: timing.presentationTimeDeltaMilliseconds,
            referenceCallbackLatencyMilliseconds: timing.referenceCallbackLatencyMilliseconds,
            captureCallbackLatencyMilliseconds: timing.captureCallbackLatencyMilliseconds,
            renderFrameLeadMilliseconds: renderFrameLeadMilliseconds
        )
    }

    private func drainCompleteCaptureFrames(
        onOutput: (AVAudioPCMBuffer) -> Void
    ) throws {
        while let frame = captureSamples.peek(frameSize) {
            do {
                let processed = try processCaptureFrame(frame, outputFrameCount: frameSize)
                captureSamples.discard(frameSize)
                onOutput(processed)
            } catch {
                try flushCaptureRemainder(onOutput: onOutput)
                throw error
            }
        }
    }

    private func processCaptureFrame(
        _ input: [Float],
        outputFrameCount: Int
    ) throws -> AVAudioPCMBuffer {
        var processed = [Float](repeating: 0, count: frameSize)
        let status = input.withUnsafeBufferPointer { inputSamples in
            processed.withUnsafeMutableBufferPointer { outputSamples in
                dahlia_aec3_process_capture(
                    processor,
                    inputSamples.baseAddress,
                    outputSamples.baseAddress,
                    inputSamples.count
                )
            }
        }
        guard status == 0,
              let output = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(outputFrameCount)
              ), let outputSamples = output.floatChannelData?[0]
        else {
            throw AudioCaptureError.echoCancellationUnavailable
        }
        output.frameLength = AVAudioFrameCount(outputFrameCount)
        if !timing.currentCaptureHasAlignedReference {
            timing.captureWithoutReferenceFrameCount += Int64(outputFrameCount)
        }
        timing.processedCaptureFrameCount += Int64(outputFrameCount)
        processed.withUnsafeBufferPointer { samples in
            outputSamples.update(from: samples.baseAddress!, count: outputFrameCount)
        }
        return output
    }

    private func validate(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.format == format, buffer.floatChannelData != nil else {
            throw AudioCaptureError.echoCancellationUnavailable
        }
    }

    private func makeBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let outputSamples = buffer.floatChannelData?[0] else {
            throw AudioCaptureError.echoCancellationUnavailable
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            outputSamples.update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    private func updateStreamDelay(
        capturePresentationTimeStamp: CMTime?
    ) {
        guard let referencePresentationTimeStamp = timing.latestReferencePresentationTimeStamp,
              let referenceProcessedHostTime = timing.latestReferenceProcessedHostTime,
              let presentationDelta = Self.milliseconds(
                  from: referencePresentationTimeStamp,
                  to: capturePresentationTimeStamp
              ), let renderToHardware = Self.milliseconds(
                  from: referenceProcessedHostTime,
                  to: referencePresentationTimeStamp
              ), let captureToProcessing = Self.milliseconds(
                  from: capturePresentationTimeStamp,
                  to: CMClockGetTime(CMClockGetHostTimeClock())
              )
        else {
            return
        }

        timing.presentationTimeDeltaMilliseconds = presentationDelta
        let delay = min(max(Int((renderToHardware + captureToProcessing).rounded()), 0), 500)
        guard dahlia_aec3_set_stream_delay_ms(processor, Int32(delay)) == 0 else { return }
        timing.streamDelayHintMilliseconds = delay
    }

    private static func milliseconds(from start: CMTime?, to end: CMTime?) -> Double? {
        guard let start, let end, start.isValid, end.isValid, start.isNumeric, end.isNumeric else {
            return nil
        }
        let milliseconds = CMTimeGetSeconds(end - start) * 1000
        guard milliseconds.isFinite, abs(milliseconds) <= 10000 else { return nil }
        return milliseconds
    }
}

private struct TimingState {
    var referenceBufferCount = 0
    var referenceFrameCount: Int64 = 0
    var captureBufferCount = 0
    var captureFrameCount: Int64 = 0
    var processedReferenceFrameCount: Int64 = 0
    var processedCaptureFrameCount: Int64 = 0
    var captureWithoutReferenceFrameCount: Int64 = 0
    var latestReferencePresentationTimeStamp: CMTime?
    var latestReferenceReceivedHostTime: CMTime?
    var latestReferenceProcessedHostTime: CMTime?
    var currentCaptureHasAlignedReference = false
    var streamDelayHintMilliseconds: Int?
    var presentationTimeDeltaMilliseconds: Double?
    var referenceCallbackLatencyMilliseconds: Double?
    var captureCallbackLatencyMilliseconds: Double?
}

private struct PendingFloatSamples {
    private var storage: [Float] = []
    private var readIndex = 0

    var count: Int {
        storage.count - readIndex
    }

    mutating func append(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        storage.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
    }

    mutating func take(_ requestedCount: Int) -> [Float]? {
        guard requestedCount > 0, count >= requestedCount else { return nil }
        let endIndex = readIndex + requestedCount
        let result = Array(storage[readIndex ..< endIndex])
        readIndex = endIndex
        compactIfNeeded()
        return result
    }

    func peek(_ requestedCount: Int) -> [Float]? {
        guard requestedCount > 0, count >= requestedCount else { return nil }
        return Array(storage[readIndex ..< readIndex + requestedCount])
    }

    mutating func discard(_ requestedCount: Int) {
        guard requestedCount > 0, count >= requestedCount else { return }
        readIndex += requestedCount
        compactIfNeeded()
    }

    private mutating func compactIfNeeded() {
        guard readIndex == storage.count || readIndex >= 4096 else { return }
        storage.removeFirst(readIndex)
        readIndex = 0
    }
}
