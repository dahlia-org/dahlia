@preconcurrency import AVFoundation
import CoreAudio

extension AudioCaptureManager {
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

    func configureVoiceProcessingGraphForCapture(
        enabled: Bool,
        inputNode: AVAudioInputNode,
        diagnosticCaptureID: UUID
    ) throws -> AVAudioFormat? {
        let format = try configureVoiceProcessingGraph(enabled: enabled, inputNode: inputNode)
        recordDiagnosticSnapshot(
            captureID: diagnosticCaptureID,
            stage: .voiceProcessingGraphConfigured,
            inputNode: inputNode
        )
        return format
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
