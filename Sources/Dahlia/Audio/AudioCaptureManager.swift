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

    private struct CaptureRequest {
        let targetFormat: AVAudioFormat
        let selectedDeviceID: AudioDeviceID?
        let bufferSize: AVAudioFrameCount
        let prefersVoiceProcessing: Bool
    }

    private enum LifecycleState {
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

    private let engine = AVAudioEngine()
    private let lifecycleQueue = DispatchQueue(label: "com.dahlia.microphone-capture.lifecycle")
    private let conversionState = OSAllocatedUnfairLock(initialState: ConversionState())
    private let handlerState = OSAllocatedUnfairLock(initialState: HandlerState())
    private var lifecycleState = LifecycleState.stopped
    private var activeRequest: CaptureRequest?
    private var hasInputTap = false
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(engineConfigurationDidChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    deinit {
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
        prefersVoiceProcessing: Bool = true
    ) throws -> AudioCaptureStartInfo {
        let request = CaptureRequest(
            targetFormat: targetFormat,
            selectedDeviceID: selectedDeviceID,
            bufferSize: bufferSize,
            prefersVoiceProcessing: prefersVoiceProcessing
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
                resetCaptureAttempt()
                lifecycleState = .stopped
                throw error
            }
        }
    }

    private func startCapture(_ request: CaptureRequest) throws -> AudioCaptureStartInfo {
        var lastError: (any Error)?
        let selectedDeviceDescription = request.selectedDeviceID.map(String.init) ?? "system-default"

        Self.logger.info(
            "Starting microphone capture; device=\(selectedDeviceDescription, privacy: .public), voiceProcessing=\(request.prefersVoiceProcessing)"
        )

        for enablesVoiceProcessing in Self.voiceProcessingAttemptOrder(
            prefersVoiceProcessing: request.prefersVoiceProcessing
        ) {
            do {
                return try startCaptureAttempt(
                    targetFormat: request.targetFormat,
                    selectedDeviceID: request.selectedDeviceID,
                    bufferSize: request.bufferSize,
                    enablesVoiceProcessing: enablesVoiceProcessing
                )
            } catch {
                lastError = error
                Self.logger.error(
                    "Microphone capture attempt failed; voiceProcessing=\(enablesVoiceProcessing), error=\(error.localizedDescription, privacy: .public)"
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
        enablesVoiceProcessing: Bool
    ) throws -> AudioCaptureStartInfo {
        let inputNode = engine.inputNode
        if inputNode.isVoiceProcessingEnabled {
            try inputNode.setVoiceProcessingEnabled(false)
        }

        if enablesVoiceProcessing {
            try enableVoiceProcessing(inputNode: inputNode)
        }

        // Enabling Voice Processing replaces AUHAL with AUVoiceIO. Apply an
        // explicitly selected device after that replacement so it remains pinned.
        if let selectedDeviceID {
            try Self.configureInputDevice(selectedDeviceID, for: inputNode)
        }

        let voiceProcessingFormat = try configureVoiceProcessingGraph(
            enabled: enablesVoiceProcessing,
            inputNode: inputNode
        )

        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidHardwareFormat
        }

        let sourceFormat = Self.captureSourceFormat(
            hardwareFormat: hardwareFormat,
            voiceProcessingFormat: voiceProcessingFormat,
            enablesVoiceProcessing: enablesVoiceProcessing
        )
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidHardwareFormat
        }

        Self.logger.info("Microphone hardware format: \(hardwareFormat.diagnosticDescription, privacy: .public)")
        Self.logger.info("Microphone source format: \(sourceFormat.diagnosticDescription, privacy: .public)")
        Self.logger.info("Microphone target format: \(targetFormat.diagnosticDescription, privacy: .public)")

        guard let audioConverter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        audioConverter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: sourceFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        hasInputTap = true

        engine.prepare()
        try engine.start()
        conversionState.withLock { state in
            state.converter = audioConverter
            state.targetFormat = targetFormat
            state.didLogFirstBuffer = false
            state.didLogConversionFailure = false
        }
        Self.logger.info("Microphone engine started; voiceProcessing=\(enablesVoiceProcessing)")
        Self.logger.info(
            "Microphone modes; preferred=\(AVCaptureDevice.preferredMicrophoneMode.rawValue), active=\(AVCaptureDevice.activeMicrophoneMode.rawValue)"
        )

        return AudioCaptureStartInfo(
            hardwareFormatDescription: hardwareFormat.diagnosticDescription,
            sourceFormatDescription: sourceFormat.diagnosticDescription,
            targetFormatDescription: targetFormat.diagnosticDescription
        )
    }

    private func enableVoiceProcessing(inputNode: AVAudioInputNode) throws {
        try inputNode.setVoiceProcessingEnabled(true)
        // macOS microphone modes are implemented by the Voice Processing unit.
        // Bypassing it would also bypass Voice Isolation selected by the user.
        inputNode.isVoiceProcessingBypassed = false
        inputNode.isVoiceProcessingInputMuted = false
        inputNode.isVoiceProcessingAGCEnabled = true
        inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
            enableAdvancedDucking: false,
            duckingLevel: .min
        )
    }

    private func configureVoiceProcessingGraph(
        enabled: Bool,
        inputNode: AVAudioInputNode
    ) throws -> AVAudioFormat? {
        guard enabled else { return nil }
        let outputNode = engine.outputNode
        let outputFormat = outputNode.inputFormat(forBus: 0)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard Self.voiceProcessingFormatsMatch(inputFormat, outputFormat) else {
            throw AudioCaptureError.invalidHardwareFormat
        }

        // Voice Processing requires the input node's output format and output
        // node's input format to match. Use the output device's accepted format
        // for both sides instead of the built-in microphone's multi-channel
        // hardware format.
        engine.connect(engine.mainMixerNode, to: outputNode, format: outputFormat)
        hasVoiceProcessingOutputConnection = true
        return inputFormat
    }

    /// キャプチャを停止する。
    func stopCapture() {
        lifecycleQueue.sync {
            guard lifecycleState != .stopped else { return }
            lifecycleState = .stopping
            activeRequest = nil
            resetCaptureAttempt()
            lifecycleState = .stopped
        }
    }

    @objc private func engineConfigurationDidChange() {
        lifecycleQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.recoverFromConfigurationChangeIfNeeded()
        }
    }

    private func recoverFromConfigurationChangeIfNeeded() {
        guard lifecycleState == .running,
              !engine.isRunning,
              let request = activeRequest else { return }
        lifecycleState = .restarting
        activeRequest = nil
        Self.logger.notice("Restarting microphone engine after a configuration change")
        resetCaptureAttempt()
        do {
            _ = try startCapture(request)
            activeRequest = request
            lifecycleState = .running
            Self.logger.notice("Microphone engine recovered after a configuration change")
        } catch {
            resetCaptureAttempt()
            lifecycleState = .stopped
            Self.logger.error(
                "Microphone engine recovery failed: \(error.localizedDescription, privacy: .public)"
            )
            notifyUnexpectedStop(Self.audioCaptureError(from: error))
        }
    }

    private func processAudioBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        let levelsHandler = onInputLevels
        levelsHandler?(AudioLevelCalculator.normalizedLevels(in: inputBuffer))

        let shouldLogFirstBuffer = conversionState.withLock { state in
            guard state.targetFormat != nil, !state.didLogFirstBuffer else { return false }
            state.didLogFirstBuffer = true
            return true
        }
        if shouldLogFirstBuffer {
            let formatDescription = inputBuffer.format.diagnosticDescription
            Self.logger.info(
                "Received first microphone buffer; frames=\(inputBuffer.frameLength), format=\(formatDescription, privacy: .public)"
            )
        }

        let conversionResult = conversionState.withLock { state -> (AVAudioPCMBuffer?, AudioCaptureError?) in
            guard let targetFormat = state.targetFormat else { return (nil, nil) }
            if state.converter?.inputFormat != inputBuffer.format {
                guard let converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat) else {
                    return (nil, state.markConversionFailure())
                }
                converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
                state.converter = converter
                Self.logger.notice(
                    "Recreated microphone converter for input format: \(inputBuffer.format.diagnosticDescription, privacy: .public)"
                )
            }
            guard let converter = state.converter,
                  let outputBuffer = AudioConverter.convert(inputBuffer, to: targetFormat, using: converter) else {
                return (nil, state.markConversionFailure())
            }
            return (outputBuffer, nil)
        }
        if let failure = conversionResult.1 {
            let inputDescription = inputBuffer.format.diagnosticDescription
            Self.logger.error("Failed to convert microphone buffer: \(inputDescription, privacy: .public)")
            lifecycleQueue.async { [weak self] in
                self?.failActiveCapture(failure)
            }
            return
        }
        if let outputBuffer = conversionResult.0 {
            onAudioBuffer?(outputBuffer)
        }
    }

    private static func configureInputDevice(_ deviceID: AudioDeviceID, for inputNode: AVAudioInputNode) throws {
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

    private func resetCaptureAttempt() {
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
    }

    private func failActiveCapture(_ error: AudioCaptureError) {
        guard lifecycleState == .running || lifecycleState == .restarting else { return }
        lifecycleState = .stopping
        activeRequest = nil
        resetCaptureAttempt()
        lifecycleState = .stopped
        notifyUnexpectedStop(error)
    }

    private func notifyUnexpectedStop(_ error: AudioCaptureError?) {
        guard let handler = onUnexpectedStop else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            handler(error)
        }
    }

    private static func audioCaptureError(from error: any Error) -> AudioCaptureError {
        error as? AudioCaptureError ?? .microphoneDeviceUnavailable
    }
}
