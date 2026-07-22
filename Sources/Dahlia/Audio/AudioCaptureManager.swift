import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Dispatch
import os

enum AudioCaptureError: Error, LocalizedError {
    case invalidHardwareFormat
    case converterCreationFailed
    case microphonePermissionDenied
    case microphoneDeviceUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidHardwareFormat:
            L10n.invalidHardwareFormat
        case .converterCreationFailed:
            L10n.converterCreationFailed
        case .microphonePermissionDenied:
            L10n.microphoneDenied
        case .microphoneDeviceUnavailable:
            L10n.microphoneUnavailable
        }
    }
}

/// AVAudioEngine を使用してマイクからオーディオをキャプチャし、
/// 指定されたターゲットフォーマットに変換して AVAudioPCMBuffer で出力する。
/// AVAudioEngine configuration must be serialized, while its tap callback runs on
/// a realtime audio thread. The queue and locks below isolate those two domains.
final class AudioCaptureManager: NSObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.dahlia", category: "MicrophoneCapture")

    struct CaptureRequest {
        let targetFormat: AVAudioFormat
        let selectedDeviceID: AudioDeviceID?
        let bufferSize: AVAudioFrameCount
        let prefersVoiceProcessing: Bool
        let context: MicrophoneCaptureContext
    }

    enum LifecycleState {
        case stopped
        case starting
        case running
        case restarting
        case stopping
    }

    private struct ConversionState {
        var converter: AVAudioConverter?
        var targetFormat: AVAudioFormat?
        var didLogFirstBuffer = false
        var didLogConversionFailure = false

        mutating func markConversionFailure() -> AudioCaptureError? {
            guard !didLogConversionFailure else { return nil }
            didLogConversionFailure = true
            return .converterCreationFailed
        }
    }

    private struct HandlerState {
        var audioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
        var inputLevels: (@Sendable ([Double]) -> Void)?
        var unexpectedStop: (@Sendable (AudioCaptureError?) -> Void)?
    }

    private(set) var engine = AVAudioEngine()
    let lifecycleQueue = DispatchQueue(label: "com.dahlia.microphone-capture.lifecycle")
    private let conversionState = OSAllocatedUnfairLock(initialState: ConversionState())
    private let handlerState = OSAllocatedUnfairLock(initialState: HandlerState())
    let healthTracker = MicrophoneCaptureHealthTracker()
    var lifecycleState = LifecycleState.stopped
    var activeRequest: CaptureRequest?
    var activeDiagnosticCaptureID: UUID?
    var healthMonitoringTask: Task<Void, Never>?
    var hasInputTap = false
    private var hasVoiceProcessingOutputConnection = false

    /// 変換済み AVAudioPCMBuffer のコールバック（オーディオスレッドから呼ばれる）
    var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { handlerState.withLock { $0.audioBuffer } }
        set { handlerState.withLock { $0.audioBuffer = newValue } }
    }

    var onInputLevels: (@Sendable ([Double]) -> Void)? {
        get { handlerState.withLock { $0.inputLevels } }
        set { handlerState.withLock { $0.inputLevels = newValue } }
    }

    var onUnexpectedStop: (@Sendable (AudioCaptureError?) -> Void)? {
        get { handlerState.withLock { $0.unexpectedStop } }
        set { handlerState.withLock { $0.unexpectedStop = newValue } }
    }

    override init() {
        super.init()
        observeEngineConfigurationChanges()
    }

    private func observeEngineConfigurationChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(engineConfigurationDidChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    deinit {
        healthMonitoringTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}

extension AudioCaptureManager {
    /// マイクのパーミッションを確認・要求する。
    static func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// マイクキャプチャを開始する。
    @discardableResult
    func startCapture(
        targetFormat: AVAudioFormat,
        selectedDeviceID: AudioDeviceID? = nil,
        bufferSize: AVAudioFrameCount = 4096,
        prefersVoiceProcessing: Bool = true,
        context: MicrophoneCaptureContext = .recording
    ) throws -> AudioCaptureStartInfo {
        let request = CaptureRequest(
            targetFormat: targetFormat,
            selectedDeviceID: selectedDeviceID,
            bufferSize: bufferSize,
            prefersVoiceProcessing: prefersVoiceProcessing,
            context: context
        )
        return try lifecycleQueue.sync {
            guard lifecycleState == .stopped else {
                throw AudioCaptureError.microphoneDeviceUnavailable
            }
            lifecycleState = .starting
            do {
                let startInfo = try startCapture(request)
                activeRequest = request
                lifecycleState = .running
                return startInfo
            } catch {
                activeDiagnosticCaptureID = nil
                resetCaptureAttempt()
                lifecycleState = .stopped
                throw error
            }
        }
    }

    func startCapture(_ request: CaptureRequest) throws -> AudioCaptureStartInfo {
        var lastError: (any Error)?
        let defaultDeviceID = Self.defaultInputDeviceID()
        let activeDeviceID = request.selectedDeviceID ?? defaultDeviceID
        let diagnosticCaptureID = MicrophoneCaptureDiagnostics.shared.beginCapture(
            context: request.context,
            requestedVoiceProcessing: request.prefersVoiceProcessing,
            selectedDeviceID: request.selectedDeviceID,
            defaultDeviceID: defaultDeviceID,
            activeDeviceID: activeDeviceID,
            activeDeviceName: activeDeviceID.flatMap(Self.deviceName),
            deviceRunningBeforeCapture: activeDeviceID.map(Self.isDeviceRunningSomewhere),
            targetFormat: request.targetFormat.diagnosticDescription,
            detail: "bufferSize=\(request.bufferSize)"
        )
        activeDiagnosticCaptureID = diagnosticCaptureID

        for enablesVoiceProcessing in Self.voiceProcessingAttemptOrder(
            prefersVoiceProcessing: request.prefersVoiceProcessing
        ) {
            MicrophoneCaptureDiagnostics.shared.record(
                captureID: diagnosticCaptureID,
                stage: enablesVoiceProcessing ? .voiceProcessingAttempt : .rawInputFallbackAttempt
            )
            do {
                return try startCaptureAttempt(
                    targetFormat: request.targetFormat,
                    selectedDeviceID: request.selectedDeviceID,
                    bufferSize: request.bufferSize,
                    enablesVoiceProcessing: enablesVoiceProcessing,
                    diagnosticCaptureID: diagnosticCaptureID
                )
            } catch {
                lastError = error
                recordDiagnosticSnapshot(
                    captureID: diagnosticCaptureID,
                    stage: .attemptFailed,
                    inputNode: engine.inputNode,
                    detail: error.localizedDescription
                )
                resetCaptureAttempt()
            }
        }

        throw lastError ?? AudioCaptureError.invalidHardwareFormat
    }

    private func startCaptureAttempt(
        targetFormat: AVAudioFormat,
        selectedDeviceID: AudioDeviceID?,
        bufferSize: AVAudioFrameCount,
        enablesVoiceProcessing: Bool,
        diagnosticCaptureID: UUID
    ) throws -> AudioCaptureStartInfo {
        let inputNode = engine.inputNode
        recordDiagnosticSnapshot(
            captureID: diagnosticCaptureID,
            stage: .inputNodeReady,
            inputNode: inputNode
        )
        let captureSetup = try prepareCaptureAttempt(
            inputNode: inputNode,
            targetFormat: targetFormat,
            selectedDeviceID: selectedDeviceID,
            enablesVoiceProcessing: enablesVoiceProcessing,
            diagnosticCaptureID: diagnosticCaptureID
        )

        installInputTap(
            on: inputNode,
            bufferSize: bufferSize,
            sourceFormat: captureSetup.source,
            diagnosticCaptureID: diagnosticCaptureID
        )
        healthTracker.begin(captureID: diagnosticCaptureID)
        do {
            try prepareAndStartEngine(inputNode: inputNode, diagnosticCaptureID: diagnosticCaptureID)
        } catch {
            healthTracker.reset()
            throw error
        }
        conversionState.withLock { state in
            state.converter = captureSetup.converter
            state.targetFormat = targetFormat
            state.didLogFirstBuffer = false
            state.didLogConversionFailure = false
        }
        startHealthMonitoring(captureID: diagnosticCaptureID)

        return AudioCaptureStartInfo(
            hardwareFormatDescription: captureSetup.hardware.diagnosticDescription,
            sourceFormatDescription: captureSetup.source.diagnosticDescription,
            targetFormatDescription: targetFormat.diagnosticDescription
        )
    }

    static func enableVoiceProcessing(inputNode: any VoiceProcessingInputConfiguring) throws {
        try inputNode.setVoiceProcessingEnabled(true)
    }

    static func configureVoiceProcessingDucking(inputNode: any VoiceProcessingInputConfiguring) {
        // Leave bypass, mute, and AGC at their system-managed defaults. Writing
        // them here reconfigures AUVoiceIO after macOS applies the user's mode.
        inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
            enableAdvancedDucking: false,
            duckingLevel: .min
        )
    }

    func configureVoiceProcessingGraph(
        enabled: Bool,
        inputNode: AVAudioInputNode
    ) throws -> AVAudioFormat? {
        guard enabled else { return nil }
        let outputNode = engine.outputNode
        let outputHardwareFormat = outputNode.outputFormat(forBus: 0)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let outputClientFormat = Self.voiceProcessingOutputClientFormat(
            inputFormat: inputFormat,
            outputHardwareFormat: outputHardwareFormat
        ) else {
            throw AudioCaptureError.invalidHardwareFormat
        }

        // AUVoiceIO requires matching client-side input and output formats. Its
        // processed microphone stream is mono, while built-in speakers are often
        // stereo. Drive the output client side with the processed input format;
        // the output node adapts that to its hardware channel layout.
        engine.connect(engine.mainMixerNode, to: outputNode, format: outputClientFormat)
        hasVoiceProcessingOutputConnection = true
        return inputFormat
    }

    /// キャプチャを停止する。
    func stopCapture() {
        lifecycleQueue.sync {
            guard lifecycleState != .stopped else { return }
            lifecycleState = .stopping
            activeRequest = nil
            finishCaptureDiagnostics(stage: .captureStopped, detail: "reason=requested")
            resetCaptureAttempt()
            activeDiagnosticCaptureID = nil
            lifecycleState = .stopped
        }
    }

    func processAudioBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        inputNode: AVAudioInputNode,
        diagnosticCaptureID: UUID
    ) {
        let shouldSampleHealthLevel = healthTracker.recordBuffer(
            captureID: diagnosticCaptureID,
            frameLength: inputBuffer.frameLength
        )
        let levelsHandler = onInputLevels
        if levelsHandler != nil || shouldSampleHealthLevel {
            let levels = AudioLevelCalculator.normalizedLevels(in: inputBuffer)
            levelsHandler?(levels)
            if shouldSampleHealthLevel, let level = levels.max() {
                healthTracker.recordLevel(level, captureID: diagnosticCaptureID)
            }
        }

        let shouldLogFirstBuffer = conversionState.withLock { state in
            guard state.targetFormat != nil, !state.didLogFirstBuffer else { return false }
            state.didLogFirstBuffer = true
            return true
        }
        if shouldLogFirstBuffer {
            Self.recordFirstAudioBufferDiagnostic(
                captureID: diagnosticCaptureID,
                inputNode: inputNode,
                frameLength: inputBuffer.frameLength
            )
        }

        let conversionResult = conversionState.withLock { state -> (AVAudioPCMBuffer?, AudioCaptureError?) in
            guard let targetFormat = state.targetFormat else { return (nil, nil) }
            if state.converter?.inputFormat != inputBuffer.format {
                guard let converter = AudioConverter.makeConverter(
                    from: inputBuffer.format,
                    to: targetFormat
                ) else {
                    return (nil, state.markConversionFailure())
                }
                converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
                state.converter = converter
                Self.logger.notice("captureID=\(diagnosticCaptureID.uuidString, privacy: .public) recreatedConverter=true")
            }
            guard let converter = state.converter,
                  let outputBuffer = AudioConverter.convert(inputBuffer, to: targetFormat, using: converter) else {
                return (nil, state.markConversionFailure())
            }
            return (outputBuffer, nil)
        }
        if let failure = conversionResult.1 {
            let inputDescription = inputBuffer.format.diagnosticDescription
            Self.logger.error(
                "captureID=\(diagnosticCaptureID.uuidString, privacy: .public) conversionFailed=true inputFormat=\(inputDescription, privacy: .public)"
            )
            lifecycleQueue.async { [weak self] in
                self?.failActiveCapture(failure)
            }
            return
        }
        if let outputBuffer = conversionResult.0 {
            onAudioBuffer?(outputBuffer)
        }
    }

    static func configureInputDevice(_ deviceID: AudioDeviceID, for inputNode: AVAudioInputNode) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioCaptureError.microphoneDeviceUnavailable
        }

        var selectedDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw AudioCaptureError.microphoneDeviceUnavailable
        }
    }

    func resetCaptureAttempt() {
        healthMonitoringTask?.cancel()
        healthMonitoringTask = nil
        healthTracker.reset()
        conversionState.withLock { state in
            state = ConversionState()
        }
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        engine.stop()
        if hasVoiceProcessingOutputConnection {
            engine.disconnectNodeOutput(engine.mainMixerNode)
            hasVoiceProcessingOutputConnection = false
        }
        if engine.inputNode.isVoiceProcessingEnabled {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        replaceEngine()
    }

    private func replaceEngine() {
        NotificationCenter.default.removeObserver(
            self,
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        engine = AVAudioEngine()
        observeEngineConfigurationChanges()
    }

    private func failActiveCapture(_ error: AudioCaptureError) {
        guard lifecycleState == .running || lifecycleState == .restarting else { return }
        lifecycleState = .stopping
        activeRequest = nil
        finishCaptureDiagnostics(stage: .unexpectedStop, detail: "error=\(error.localizedDescription)")
        resetCaptureAttempt()
        activeDiagnosticCaptureID = nil
        lifecycleState = .stopped
        notifyUnexpectedStop(error)
    }

    func notifyUnexpectedStop(_ error: AudioCaptureError?) {
        guard let handler = onUnexpectedStop else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            handler(error)
        }
    }

    static func audioCaptureError(from error: any Error) -> AudioCaptureError {
        error as? AudioCaptureError ?? .microphoneDeviceUnavailable
    }
}
