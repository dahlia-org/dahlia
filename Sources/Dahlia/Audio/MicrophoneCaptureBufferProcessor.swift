@preconcurrency import AVFoundation
@preconcurrency import CoreMedia

protocol EchoCancellationProcessing: AnyObject {
    var format: AVAudioFormat { get }
    var latency: TimeInterval { get }

    func processRender(
        _ buffer: AVAudioPCMBuffer,
        presentationTimeStamp: CMTime?,
        receivedHostTime: CMTime?
    ) throws
    func processCapture(
        _ buffer: AVAudioPCMBuffer,
        presentationTimeStamp: CMTime?,
        receivedHostTime: CMTime?,
        referenceWasReady: Bool?,
        onOutput: (AVAudioPCMBuffer) -> Void
    ) throws
    func flushCaptureRemainder(onOutput: (AVAudioPCMBuffer) -> Void) throws
    func finish(onOutput: (AVAudioPCMBuffer) -> Void) throws
    func statistics() -> WebRTCAEC3Statistics
}

/// ScreenCaptureKit の microphone/reference callback を同じ serial queue 上で処理し、
/// raw または AEC3 処理済みのマイク音声を録音パイプライン向け形式で出力する。
final class MicrophoneCaptureBufferProcessor: @unchecked Sendable {
    static let maximumEchoAlignmentHold: TimeInterval = 0.1

    let captureFormat: AVAudioFormat
    let processingLatency: TimeInterval?
    let usesEchoCancellation: Bool

    var onRawBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onProcessedBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onReferenceBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onOutputBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onEchoCancellationStatistics: (@Sendable (WebRTCAEC3Statistics) -> Void)?
    var onEchoCancellationBypassed: (@Sendable (Error) -> Void)?
    var onFailure: (@Sendable (Error) -> Void)?

    private let targetFormat: AVAudioFormat
    private let outputConverter: AVAudioConverter?
    private let echoCancellationProcessor: (any EchoCancellationProcessing)?
    private var pendingCaptures: [ScreenCaptureAudioBuffer] = []
    private var latestReferenceEndPresentationTimeStamp: CMTime?
    private var latestCapturePresentationTimeStamp: CMTime?
    private var processedBufferCount = 0
    private var isEchoCancellationBypassed = false
    private var didFail = false
    private var didReportBypass = false

    init(
        targetFormat: AVAudioFormat,
        usesEchoCancellation: Bool,
        makeEchoCancellationProcessor: () throws -> any EchoCancellationProcessing = {
            try WebRTCAEC3Processor()
        }
    ) throws {
        self.targetFormat = targetFormat
        self.usesEchoCancellation = usesEchoCancellation

        if usesEchoCancellation {
            let processor = try makeEchoCancellationProcessor()
            captureFormat = processor.format
            processingLatency = processor.latency + Self.maximumEchoAlignmentHold
            echoCancellationProcessor = processor
            if processor.format == targetFormat {
                outputConverter = nil
            } else {
                guard let converter = AudioConverter.makeConverter(from: processor.format, to: targetFormat) else {
                    throw AudioCaptureError.converterCreationFailed
                }
                converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
                outputConverter = converter
            }
        } else {
            captureFormat = targetFormat
            processingLatency = nil
            echoCancellationProcessor = nil
            outputConverter = nil
        }
    }

    func acceptMicrophone(_ audio: ScreenCaptureAudioBuffer) {
        guard !didFail else { return }
        onRawBuffer?(audio.buffer)

        guard usesEchoCancellation, !isEchoCancellationBypassed else {
            deliverOrFail(audio.buffer, isProcessed: false)
            return
        }

        pendingCaptures.append(audio)
        latestCapturePresentationTimeStamp = audio.presentationTimeStamp
        do {
            try drainPendingCaptures(force: false)
        } catch {
            bypassEchoCancellation(error)
        }
    }

    func acceptSystemAudio(_ audio: ScreenCaptureAudioBuffer) {
        guard !didFail, usesEchoCancellation else { return }
        onReferenceBuffer?(audio.buffer)
        guard !isEchoCancellationBypassed, let echoCancellationProcessor else { return }

        do {
            latestReferenceEndPresentationTimeStamp = audio.endPresentationTimeStamp
            try echoCancellationProcessor.processRender(
                audio.buffer,
                presentationTimeStamp: audio.presentationTimeStamp,
                receivedHostTime: audio.receivedHostTime
            )
            try drainPendingCaptures(force: false)
        } catch {
            bypassEchoCancellation(error)
        }
    }

    func handleSystemAudioFailure(_ error: Error) {
        guard usesEchoCancellation else { return }
        bypassEchoCancellation(error)
    }

    func finish() throws {
        guard !didFail else { return }
        do {
            try drainPendingCaptures(force: true)
        } catch {
            bypassEchoCancellation(error)
            return
        }
        guard usesEchoCancellation,
              !isEchoCancellationBypassed,
              let echoCancellationProcessor else { return }

        do {
            try echoCancellationProcessor.finish { [weak self] buffer in
                self?.deliverProcessedOrFail(buffer)
            }
            onEchoCancellationStatistics?(echoCancellationProcessor.statistics())
        } catch {
            bypassEchoCancellation(error)
        }
    }

    private func drainPendingCaptures(force: Bool) throws {
        while let audio = pendingCaptures.first {
            let referenceWasReady = EchoCaptureAlignment.referenceCoversCapture(
                referenceEnd: latestReferenceEndPresentationTimeStamp,
                capturePresentationTimeStamp: audio.presentationTimeStamp
            )
            let holdExpired = EchoCaptureAlignment.holdExpired(
                oldestCapturePresentationTimeStamp: audio.presentationTimeStamp,
                latestCapturePresentationTimeStamp: latestCapturePresentationTimeStamp,
                maximumHold: Self.maximumEchoAlignmentHold
            )
            guard force || referenceWasReady || holdExpired else { return }
            pendingCaptures.removeFirst()

            if referenceWasReady, !isEchoCancellationBypassed {
                try processEchoCancellationCapture(audio)
            } else {
                try flushEchoCancellationRemainder()
                try deliver(audio.buffer, isProcessed: false)
            }
        }
    }

    private func processEchoCancellationCapture(_ audio: ScreenCaptureAudioBuffer) throws {
        guard let echoCancellationProcessor else {
            throw AudioCaptureError.echoCancellationUnavailable
        }
        try echoCancellationProcessor.processCapture(
            audio.buffer,
            presentationTimeStamp: audio.presentationTimeStamp,
            receivedHostTime: audio.receivedHostTime,
            referenceWasReady: true
        ) { [weak self] buffer in
            guard let self else { return }
            deliverProcessedOrFail(buffer)
            processedBufferCount += 1
            if processedBufferCount.isMultiple(of: 100) {
                onEchoCancellationStatistics?(echoCancellationProcessor.statistics())
            }
        }
    }

    private func bypassEchoCancellation(_ error: Error) {
        guard !didFail else { return }
        isEchoCancellationBypassed = true
        if !didReportBypass {
            didReportBypass = true
            onEchoCancellationBypassed?(error)
        }

        do {
            try flushEchoCancellationRemainder()
        } catch {
            fail(error)
            return
        }

        let captures = pendingCaptures
        pendingCaptures.removeAll(keepingCapacity: false)
        for audio in captures {
            guard !didFail else { return }
            deliverOrFail(audio.buffer, isProcessed: false)
        }
    }

    private func flushEchoCancellationRemainder() throws {
        guard let echoCancellationProcessor else { return }
        try echoCancellationProcessor.flushCaptureRemainder { [weak self] buffer in
            self?.deliverProcessedOrFail(buffer)
        }
    }

    private func deliverProcessedOrFail(_ buffer: AVAudioPCMBuffer) {
        guard !didFail else { return }
        deliverOrFail(buffer, isProcessed: true)
    }

    private func deliverOrFail(_ buffer: AVAudioPCMBuffer, isProcessed: Bool) {
        do {
            try deliver(buffer, isProcessed: isProcessed)
        } catch {
            fail(error)
        }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer, isProcessed: Bool) throws {
        if isProcessed {
            onProcessedBuffer?(buffer)
        }
        let output: AVAudioPCMBuffer
        if buffer.format == targetFormat {
            output = buffer
        } else if let outputConverter,
                  let converted = AudioConverter.convert(buffer, to: targetFormat, using: outputConverter) {
            output = converted
        } else {
            throw AudioCaptureError.converterCreationFailed
        }
        onOutputBuffer?(output)
    }

    private func fail(_ error: Error) {
        guard !didFail else { return }
        didFail = true
        onFailure?(error)
    }
}

enum EchoCaptureAlignment {
    static func referenceCoversCapture(
        referenceEnd: CMTime?,
        capturePresentationTimeStamp: CMTime
    ) -> Bool {
        guard capturePresentationTimeStamp.isValid,
              let referenceEnd,
              referenceEnd.isValid else {
            return false
        }
        return CMTimeCompare(referenceEnd, capturePresentationTimeStamp) >= 0
    }

    static func holdExpired(
        oldestCapturePresentationTimeStamp: CMTime,
        latestCapturePresentationTimeStamp: CMTime?,
        maximumHold: TimeInterval
    ) -> Bool {
        guard oldestCapturePresentationTimeStamp.isValid,
              let latestCapturePresentationTimeStamp,
              latestCapturePresentationTimeStamp.isValid else {
            return true
        }
        let heldDuration = CMTimeGetSeconds(
            latestCapturePresentationTimeStamp - oldestCapturePresentationTimeStamp
        )
        return heldDuration.isFinite && heldDuration >= maximumHold
    }
}
