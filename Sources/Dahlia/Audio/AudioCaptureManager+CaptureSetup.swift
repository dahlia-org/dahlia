@preconcurrency import AVFoundation
import CoreAudio

extension AudioCaptureManager {
    func prepareCaptureAttempt(
        inputNode: AVAudioInputNode,
        targetFormat: AVAudioFormat,
        selectedDeviceID: AudioDeviceID?,
        enablesVoiceProcessing: Bool,
        diagnosticCaptureID: UUID
    ) throws -> (hardware: AVAudioFormat, source: AVAudioFormat, converter: AVAudioConverter) {
        try configureVoiceProcessingInput(
            inputNode,
            enabled: enablesVoiceProcessing,
            diagnosticCaptureID: diagnosticCaptureID
        )
        try configureInputDeviceForCapture(
            selectedDeviceID,
            inputNode: inputNode,
            diagnosticCaptureID: diagnosticCaptureID
        )
        let voiceProcessingFormat = try configureVoiceProcessingGraph(
            enabled: enablesVoiceProcessing,
            inputNode: inputNode
        )
        let formats = try Self.validatedCaptureFormats(
            inputNode: inputNode,
            voiceProcessingFormat: voiceProcessingFormat,
            enablesVoiceProcessing: enablesVoiceProcessing
        )
        recordDiagnosticSnapshot(
            captureID: diagnosticCaptureID,
            stage: .voiceProcessingGraphConfigured,
            inputNode: inputNode,
            inputHardwareFormat: formats.hardware.diagnosticDescription,
            inputClientFormat: formats.source.diagnosticDescription,
            outputHardwareFormat: enablesVoiceProcessing
                ? engine.outputNode.outputFormat(forBus: 0).diagnosticDescription
                : nil,
            targetFormat: targetFormat.diagnosticDescription
        )
        guard let converter = AudioConverter.makeConverter(from: formats.source, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        return (formats.hardware, formats.source, converter)
    }

    func installInputTap(
        on inputNode: AVAudioInputNode,
        bufferSize: AVAudioFrameCount,
        sourceFormat: AVAudioFormat,
        diagnosticCaptureID: UUID
    ) {
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: sourceFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(
                buffer,
                inputNode: inputNode,
                diagnosticCaptureID: diagnosticCaptureID
            )
        }
        hasInputTap = true
        recordDiagnosticSnapshot(
            captureID: diagnosticCaptureID,
            stage: .inputTapInstalled,
            inputNode: inputNode
        )
    }

    func prepareAndStartEngine(
        inputNode: AVAudioInputNode,
        diagnosticCaptureID: UUID
    ) throws {
        engine.prepare()
        recordDiagnosticSnapshot(
            captureID: diagnosticCaptureID,
            stage: .enginePrepared,
            inputNode: inputNode
        )
        try engine.start()
        recordDiagnosticSnapshot(
            captureID: diagnosticCaptureID,
            stage: .engineStarted,
            inputNode: inputNode
        )
    }

    func configureInputDeviceForCapture(
        _ selectedDeviceID: AudioDeviceID?,
        inputNode: AVAudioInputNode,
        diagnosticCaptureID: UUID
    ) throws {
        if let selectedDeviceID {
            try Self.configureInputDevice(selectedDeviceID, for: inputNode)
        }
        recordDiagnosticSnapshot(
            captureID: diagnosticCaptureID,
            stage: .inputDeviceConfigured,
            inputNode: inputNode,
            detail: selectedDeviceID.map(String.init) ?? "system-default"
        )
    }

    static func validatedCaptureFormats(
        inputNode: AVAudioInputNode,
        voiceProcessingFormat: AVAudioFormat?,
        enablesVoiceProcessing: Bool
    ) throws -> (hardware: AVAudioFormat, source: AVAudioFormat) {
        let hardwareFormat = inputNode.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidHardwareFormat
        }
        let sourceFormat = captureSourceFormat(
            hardwareFormat: hardwareFormat,
            voiceProcessingFormat: voiceProcessingFormat,
            enablesVoiceProcessing: enablesVoiceProcessing
        )
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidHardwareFormat
        }
        return (hardwareFormat, sourceFormat)
    }
}
