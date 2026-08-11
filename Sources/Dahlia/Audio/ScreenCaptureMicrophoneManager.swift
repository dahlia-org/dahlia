@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os
@preconcurrency import ScreenCaptureKit

struct ScreenCaptureAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let presentationTimeStamp: CMTime
    let receivedHostTime: CMTime

    var endPresentationTimeStamp: CMTime {
        presentationTimeStamp + CMTime(
            value: CMTimeValue(buffer.frameLength),
            timescale: CMTimeScale(buffer.format.sampleRate.rounded())
        )
    }
}

/// ScreenCaptureKit の microphone output から、AVAudioEngine を開かずにマイク PCM を取得する。
final class ScreenCaptureMicrophoneManager: NSObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.dahlia", category: "ScreenCaptureMicrophone")

    private struct HandlerState {
        var audioBuffer: (@Sendable (ScreenCaptureAudioBuffer) -> Void)?
        var systemAudioBuffer: (@Sendable (ScreenCaptureAudioBuffer) -> Void)?
        var systemAudioFailure: (@Sendable (Error) -> Void)?
        var unexpectedStop: (@Sendable (Error?) -> Void)?
    }

    private struct ConversionResult {
        let buffer: AVAudioPCMBuffer?
        let firstFormatDescription: String?
        let error: Error?
    }

    private struct ConversionState {
        var targetFormat: AVAudioFormat?
        var sourceFormat: AVAudioFormat?
        var converter: AVAudioConverter?
        var lastFormatDescription: CMFormatDescription?
        var didReceiveFirstBuffer = false
    }

    private struct LifecycleState: @unchecked Sendable {
        var stream: SCStream?
        var configuration: SCStreamConfiguration?
        var requestedStop = false
        var didReportMicrophoneFailure = false
        var diagnosticCaptureID: UUID?
    }

    private let audioQueue = DispatchQueue(label: "com.dahlia.microphone-capture.screencapturekit", qos: .userInitiated)
    private let handlerState = OSAllocatedUnfairLock(initialState: HandlerState())
    private let microphoneConversionState = OSAllocatedUnfairLock(initialState: ConversionState())
    private let systemAudioConversionState = OSAllocatedUnfairLock(initialState: ConversionState())
    private let lifecycleState = OSAllocatedUnfairLock(initialState: LifecycleState())

    var onAudioBuffer: (@Sendable (ScreenCaptureAudioBuffer) -> Void)? {
        get { handlerState.withLock { $0.audioBuffer } }
        set { handlerState.withLock { $0.audioBuffer = newValue } }
    }

    var onUnexpectedStop: (@Sendable (Error?) -> Void)? {
        get { handlerState.withLock { $0.unexpectedStop } }
        set { handlerState.withLock { $0.unexpectedStop = newValue } }
    }

    var onSystemAudioBuffer: (@Sendable (ScreenCaptureAudioBuffer) -> Void)? {
        get { handlerState.withLock { $0.systemAudioBuffer } }
        set { handlerState.withLock { $0.systemAudioBuffer = newValue } }
    }

    var onSystemAudioFailure: (@Sendable (Error) -> Void)? {
        get { handlerState.withLock { $0.systemAudioFailure } }
        set { handlerState.withLock { $0.systemAudioFailure = newValue } }
    }

    func startCapture(
        targetFormat: AVAudioFormat,
        selectedDeviceID: AudioDeviceID?,
        defaultDeviceID: AudioDeviceID?,
        activeDeviceID: AudioDeviceID,
        path: MicrophoneDiagnosticCapturePath,
        context: MicrophoneCaptureContext = .audioTest
    ) async throws -> AudioCaptureStartInfo {
        guard let microphoneUID = AudioCaptureManager.deviceUID(for: activeDeviceID) else {
            throw AudioCaptureError.microphoneDeviceUnavailable
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw SystemAudioCaptureError.screenRecordingPermissionDenied
        }
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayFound
        }

        let bundleID = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let configuration = SCStreamConfiguration()
        let capturesSystemAudio = path == .screenCaptureEchoCancellation
        configuration.capturesAudio = capturesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        if capturesSystemAudio {
            configuration.sampleRate = Int(targetFormat.sampleRate)
            configuration.channelCount = Int(targetFormat.channelCount)
        }
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = microphoneUID
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let diagnosticCaptureID = MicrophoneCaptureDiagnostics.shared.beginCapture(
            context: context,
            selectedDeviceID: selectedDeviceID,
            defaultDeviceID: defaultDeviceID,
            activeDeviceID: activeDeviceID,
            activeDeviceName: AudioCaptureManager.deviceName(for: activeDeviceID),
            deviceRunningBeforeCapture: AudioCaptureManager.isDeviceRunningSomewhere(activeDeviceID),
            targetFormat: targetFormat.diagnosticDescription,
            detail: "backend=\(path.rawValue) microphoneUIDConfigured=true"
        )

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            if capturesSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            }
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
            microphoneConversionState.withLock { state in
                state = ConversionState(targetFormat: targetFormat)
            }
            systemAudioConversionState.withLock { state in
                state = ConversionState(targetFormat: capturesSystemAudio ? targetFormat : nil)
            }
            lifecycleState.withLock { state in
                state.stream = stream
                state.configuration = configuration
                state.requestedStop = false
                state.didReportMicrophoneFailure = false
                state.diagnosticCaptureID = diagnosticCaptureID
            }
            try await stream.startCapture()
        } catch {
            let shouldStop = lifecycleState.withLock { state in
                guard state.stream === stream else { return false }
                state.requestedStop = true
                state.stream = nil
                return true
            }
            if shouldStop {
                try? await stream.stopCapture()
            }
            await drainAudioQueue()
            clearCaptureState()
            MicrophoneCaptureDiagnostics.shared.record(
                captureID: diagnosticCaptureID,
                stage: .attemptFailed,
                detail: error.localizedDescription
            )
            throw error
        }

        MicrophoneCaptureDiagnostics.shared.record(
            captureID: diagnosticCaptureID,
            stage: .screenCaptureKitConfigured,
            activeDeviceID: activeDeviceID,
            activeDeviceName: AudioCaptureManager.deviceName(for: activeDeviceID),
            targetFormat: targetFormat.diagnosticDescription,
            detail: "microphoneUIDConfigured=true systemAudioReference=\(capturesSystemAudio)"
        )
        Self.logger.notice("ScreenCaptureKit microphone capture started; path=\(path.rawValue, privacy: .public)")

        let hardwareDescription = AudioCaptureManager.deviceName(for: activeDeviceID) ?? "System default microphone"
        return AudioCaptureStartInfo(
            hardwareFormatDescription: hardwareDescription,
            sourceFormatDescription: "ScreenCaptureKit native microphone format",
            targetFormatDescription: targetFormat.diagnosticDescription,
            capturePath: path
        )
    }

    func stopCaptureAndWait() async {
        let capture = lifecycleState.withLock { state -> (stream: SCStream?, captureID: UUID?) in
            state.requestedStop = true
            let capture = (state.stream, state.diagnosticCaptureID)
            state.stream = nil
            return capture
        }
        if let stream = capture.stream {
            try? await stream.stopCapture()
        }
        await drainAudioQueue()
        if let captureID = capture.captureID {
            MicrophoneCaptureDiagnostics.shared.record(
                captureID: captureID,
                stage: .captureStopped,
                detail: "reason=requested"
            )
        }
        clearCaptureState()
    }

    func disableSystemAudioCapture() {
        systemAudioConversionState.withLock { state in
            state = ConversionState()
        }
        guard let capture = lifecycleState.withLock({ state -> (
            stream: SCStream,
            configuration: SCStreamConfiguration
        )? in
            guard let stream = state.stream,
                  let configuration = state.configuration,
                  configuration.capturesAudio else { return nil }
            configuration.capturesAudio = false
            return (stream, configuration)
        }) else { return }

        try? capture.stream.removeStreamOutput(self, type: .audio)
        Task { [weak self] in
            do {
                try await capture.stream.updateConfiguration(capture.configuration)
            } catch {
                Self.logger.error(
                    "Failed to disable system audio after AEC bypass: \(error.localizedDescription, privacy: .public)"
                )
                self?.systemAudioConversionState.withLock { $0 = ConversionState() }
            }
        }
    }

    func recordEchoCancellationConfiguration(latency: TimeInterval, format: AVAudioFormat) {
        guard let captureID = lifecycleState.withLock({ $0.diagnosticCaptureID }) else { return }
        MicrophoneCaptureDiagnostics.shared.record(
            captureID: captureID,
            stage: .echoCancellationConfigured,
            inputClientFormat: format.diagnosticDescription,
            detail: "backend=WebRTC-AEC3 latencyMilliseconds="
                + (latency * 1000).formatted(.number.precision(.fractionLength(1)))
                + " systemAudioReference=true"
        )
    }

    func recordEchoCancellationMetrics(_ statistics: WebRTCAEC3Statistics) {
        guard let captureID = lifecycleState.withLock({ $0.diagnosticCaptureID }) else { return }
        let erle = statistics.echoReturnLossEnhancement?.formatted(
            .number.precision(.fractionLength(1))
        ) ?? "unavailable"
        let delay = statistics.delayMilliseconds?.formatted() ?? "unavailable"
        let likelihood = statistics.residualEchoLikelihood?.formatted(
            .number.precision(.fractionLength(3))
        ) ?? "unavailable"
        let streamDelayHint = statistics.streamDelayHintMilliseconds?.formatted() ?? "unavailable"
        let presentationDelta = Self.formattedMilliseconds(statistics.presentationTimeDeltaMilliseconds)
        let referenceLatency = Self.formattedMilliseconds(statistics.referenceCallbackLatencyMilliseconds)
        let captureLatency = Self.formattedMilliseconds(statistics.captureCallbackLatencyMilliseconds)
        let renderLead = Self.formattedMilliseconds(statistics.renderFrameLeadMilliseconds)
        MicrophoneCaptureDiagnostics.shared.record(
            captureID: captureID,
            stage: .echoCancellationMetrics,
            detail: "ERLE=\(erle)dB delay=\(delay)ms residualEchoLikelihood=\(likelihood) "
                + "referenceBuffers=\(statistics.referenceBufferCount) "
                + "referenceFrames=\(statistics.referenceFrameCount) "
                + "captureFrames=\(statistics.captureFrameCount) "
                + "captureWithoutAlignedReferenceFrames=\(statistics.captureWithoutReferenceFrameCount) "
                + "streamDelayHint=\(streamDelayHint)ms ptsDelta=\(presentationDelta) "
                + "referenceCallbackLatency=\(referenceLatency) captureCallbackLatency=\(captureLatency) "
                + "renderFrameLead=\(renderLead)"
        )
    }

    private static func formattedMilliseconds(_ value: Double?) -> String {
        guard let value else { return "unavailable" }
        return value.formatted(.number.precision(.fractionLength(1))) + "ms"
    }

    private func processMicrophone(_ sampleBuffer: CMSampleBuffer, receivedHostTime: CMTime) {
        let sampleBuffer = UncheckedSampleBuffer(value: sampleBuffer)
        let presentationTimeStamp = sampleBuffer.value.presentationTimeStamp
        let result = microphoneConversionState.withLock { state in
            Self.convert(sampleBuffer.value, state: &state)
        }

        if let error = result.error {
            reportMicrophoneFailure(error)
            return
        }
        if let firstFormat = result.firstFormatDescription,
           let captureID = lifecycleState.withLock({ $0.diagnosticCaptureID }) {
            MicrophoneCaptureDiagnostics.shared.record(
                captureID: captureID,
                stage: .firstAudioBufferReceived,
                inputHardwareFormat: firstFormat,
                inputClientFormat: result.buffer?.format.diagnosticDescription,
                detail: "backend=ScreenCaptureKit stream=microphone "
                    + Self.timingDescription(
                        presentationTimeStamp: presentationTimeStamp,
                        receivedHostTime: receivedHostTime
                    )
            )
        }
        if let outputBuffer = result.buffer {
            onAudioBuffer?(ScreenCaptureAudioBuffer(
                buffer: outputBuffer,
                presentationTimeStamp: presentationTimeStamp,
                receivedHostTime: receivedHostTime
            ))
        }
    }

    private func processSystemAudio(_ sampleBuffer: CMSampleBuffer, receivedHostTime: CMTime) {
        let sampleBuffer = UncheckedSampleBuffer(value: sampleBuffer)
        let presentationTimeStamp = sampleBuffer.value.presentationTimeStamp
        let result = systemAudioConversionState.withLock { state in
            Self.convert(sampleBuffer.value, state: &state)
        }
        if let error = result.error {
            onSystemAudioFailure?(error)
            return
        }
        if let firstFormat = result.firstFormatDescription,
           let captureID = lifecycleState.withLock({ $0.diagnosticCaptureID }) {
            MicrophoneCaptureDiagnostics.shared.record(
                captureID: captureID,
                stage: .firstSystemAudioBufferReceived,
                inputHardwareFormat: firstFormat,
                inputClientFormat: result.buffer?.format.diagnosticDescription,
                detail: "backend=ScreenCaptureKit stream=systemAudioReference "
                    + Self.timingDescription(
                        presentationTimeStamp: presentationTimeStamp,
                        receivedHostTime: receivedHostTime
                    )
            )
        }
        if let outputBuffer = result.buffer {
            onSystemAudioBuffer?(ScreenCaptureAudioBuffer(
                buffer: outputBuffer,
                presentationTimeStamp: presentationTimeStamp,
                receivedHostTime: receivedHostTime
            ))
        }
    }

    private static func timingDescription(
        presentationTimeStamp: CMTime,
        receivedHostTime: CMTime
    ) -> String {
        let presentationSeconds = presentationTimeStamp.seconds.formatted(
            .number.precision(.fractionLength(6))
        )
        let receivedSeconds = receivedHostTime.seconds.formatted(
            .number.precision(.fractionLength(6))
        )
        return "pts=\(presentationSeconds)s receivedHostTime=\(receivedSeconds)s"
    }

    private static func convert(
        _ sampleBuffer: CMSampleBuffer,
        state: inout ConversionState
    ) -> ConversionResult {
        guard let targetFormat = state.targetFormat else {
            return ConversionResult(buffer: nil, firstFormatDescription: nil, error: nil)
        }
        guard let formatDescription = sampleBuffer.formatDescription else {
            return ConversionResult(
                buffer: nil,
                firstFormatDescription: nil,
                error: AudioCaptureError.invalidHardwareFormat
            )
        }

        let formatChanged = state.lastFormatDescription.map {
            !CMFormatDescriptionEqual(formatDescription, otherFormatDescription: $0)
        } ?? true
        if formatChanged {
            guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
                  let sourceFormat = AVAudioFormat(streamDescription: streamDescription),
                  let converter = AudioConverter.makeConverter(from: sourceFormat, to: targetFormat)
            else {
                return ConversionResult(
                    buffer: nil,
                    firstFormatDescription: nil,
                    error: AudioCaptureError.converterCreationFailed
                )
            }
            converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
            state.lastFormatDescription = formatDescription
            state.sourceFormat = sourceFormat
            state.converter = converter
        }

        guard let sourceFormat = state.sourceFormat,
              let converter = state.converter else {
            return ConversionResult(
                buffer: nil,
                firstFormatDescription: nil,
                error: AudioCaptureError.converterCreationFailed
            )
        }
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0 else {
            return ConversionResult(buffer: nil, firstFormatDescription: nil, error: nil)
        }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return ConversionResult(
                buffer: nil,
                firstFormatDescription: nil,
                error: AudioCaptureError.converterCreationFailed
            )
        }
        inputBuffer.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        ) == noErr,
            let outputBuffer = AudioConverter.convert(inputBuffer, to: targetFormat, using: converter)
        else {
            return ConversionResult(
                buffer: nil,
                firstFormatDescription: nil,
                error: AudioCaptureError.converterCreationFailed
            )
        }

        let firstFormat = state.didReceiveFirstBuffer ? nil : sourceFormat.diagnosticDescription
        state.didReceiveFirstBuffer = true
        return ConversionResult(buffer: outputBuffer, firstFormatDescription: firstFormat, error: nil)
    }

    private func reportMicrophoneFailure(_ error: Error) {
        let shouldReport = lifecycleState.withLock { state in
            guard !state.requestedStop, !state.didReportMicrophoneFailure else { return false }
            state.didReportMicrophoneFailure = true
            return true
        }
        if shouldReport {
            onUnexpectedStop?(error)
        }
    }

    private func clearCaptureState() {
        microphoneConversionState.withLock { $0 = ConversionState() }
        systemAudioConversionState.withLock { $0 = ConversionState() }
        lifecycleState.withLock { state in
            state.stream = nil
            state.configuration = nil
            state.diagnosticCaptureID = nil
        }
    }

    private func drainAudioQueue() async {
        await withCheckedContinuation { continuation in
            audioQueue.async {
                continuation.resume()
            }
        }
    }
}

private struct UncheckedSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer
}

extension ScreenCaptureMicrophoneManager: SCStreamOutput {
    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let receivedHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        switch type {
        case .microphone:
            processMicrophone(sampleBuffer, receivedHostTime: receivedHostTime)
        case .audio:
            processSystemAudio(sampleBuffer, receivedHostTime: receivedHostTime)
        default:
            break
        }
    }
}

extension ScreenCaptureMicrophoneManager: SCStreamDelegate {
    func stream(_: SCStream, didStopWithError error: any Error) {
        let stop = lifecycleState.withLock { state -> (requested: Bool, captureID: UUID?) in
            let stop = (state.requestedStop, state.diagnosticCaptureID)
            state.stream = nil
            return stop
        }
        guard !stop.requested else { return }
        if let captureID = stop.captureID {
            MicrophoneCaptureDiagnostics.shared.record(
                captureID: captureID,
                stage: .unexpectedStop,
                detail: error.localizedDescription
            )
        }
        clearCaptureState()
        onUnexpectedStop?(error)
    }
}
