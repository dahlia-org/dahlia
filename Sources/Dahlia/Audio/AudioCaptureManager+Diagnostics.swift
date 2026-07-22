@preconcurrency import AVFoundation
import Dispatch

extension AudioCaptureManager {
    func configureVoiceProcessingInput(
        _ inputNode: AVAudioInputNode,
        enabled: Bool,
        diagnosticCaptureID: UUID
    ) throws {
        if inputNode.isVoiceProcessingEnabled {
            try inputNode.setVoiceProcessingEnabled(false)
            recordDiagnosticSnapshot(
                captureID: diagnosticCaptureID,
                stage: .existingVoiceProcessingDisabled,
                inputNode: inputNode
            )
        }

        guard enabled else { return }
        try Self.enableVoiceProcessing(inputNode: inputNode)
        recordDiagnosticSnapshot(
            captureID: diagnosticCaptureID,
            stage: .voiceProcessingEnabled,
            inputNode: inputNode
        )
        Self.configureVoiceProcessingDucking(inputNode: inputNode)
        recordDiagnosticSnapshot(
            captureID: diagnosticCaptureID,
            stage: .duckingConfigured,
            inputNode: inputNode
        )
    }

    func recordDiagnosticSnapshot(
        captureID: UUID,
        stage: MicrophoneCaptureDiagnosticStage,
        inputNode: AVAudioInputNode,
        inputHardwareFormat: String? = nil,
        inputClientFormat: String? = nil,
        outputHardwareFormat: String? = nil,
        targetFormat: String? = nil,
        detail: String? = nil
    ) {
        let activeDeviceID = Self.currentDeviceID(for: inputNode)
        MicrophoneCaptureDiagnostics.shared.record(
            captureID: captureID,
            stage: stage,
            voiceProcessingEnabled: inputNode.isVoiceProcessingEnabled,
            voiceProcessingBypassed: inputNode.isVoiceProcessingBypassed,
            voiceProcessingInputMuted: inputNode.isVoiceProcessingInputMuted,
            voiceProcessingAGCEnabled: inputNode.isVoiceProcessingAGCEnabled,
            defaultDeviceID: Self.defaultInputDeviceID(),
            activeDeviceID: activeDeviceID,
            activeDeviceName: activeDeviceID.flatMap(Self.deviceName),
            engineRunning: engine.isRunning,
            inputHardwareFormat: inputHardwareFormat ?? inputNode.inputFormat(forBus: 0).diagnosticDescription,
            inputClientFormat: inputClientFormat ?? inputNode.outputFormat(forBus: 0).diagnosticDescription,
            outputHardwareFormat: outputHardwareFormat,
            targetFormat: targetFormat,
            detail: detail
        )
    }

    func startHealthMonitoring(captureID: UUID) {
        healthMonitoringTask?.cancel()
        healthMonitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard let self,
                      let snapshot = healthTracker.snapshot(captureID: captureID) else { return }
                MicrophoneCaptureDiagnostics.shared.record(
                    captureID: captureID,
                    stage: .captureHealth,
                    detail: snapshot.diagnosticDescription
                )
            }
        }
    }

    func finishCaptureDiagnostics(
        stage: MicrophoneCaptureDiagnosticStage,
        detail: String
    ) {
        guard let captureID = activeDiagnosticCaptureID else { return }
        healthMonitoringTask?.cancel()
        healthMonitoringTask = nil
        let summary = healthTracker.finish(captureID: captureID)?.diagnosticDescription
        let combinedDetail = [detail, summary].compactMap(\.self).joined(separator: " ")
        recordDiagnosticSnapshot(
            captureID: captureID,
            stage: stage,
            inputNode: engine.inputNode,
            detail: combinedDetail
        )
    }

    static func recordFirstAudioBufferDiagnostic(
        captureID: UUID,
        inputNode: AVAudioInputNode,
        frameLength: AVAudioFrameCount
    ) {
        DispatchQueue.global(qos: .utility).async {
            MicrophoneCaptureDiagnostics.shared.record(
                captureID: captureID,
                stage: .firstAudioBufferReceived,
                voiceProcessingEnabled: inputNode.isVoiceProcessingEnabled,
                voiceProcessingBypassed: inputNode.isVoiceProcessingBypassed,
                voiceProcessingInputMuted: inputNode.isVoiceProcessingInputMuted,
                voiceProcessingAGCEnabled: inputNode.isVoiceProcessingAGCEnabled,
                activeDeviceID: Self.currentDeviceID(for: inputNode),
                engineRunning: true,
                inputClientFormat: inputNode.outputFormat(forBus: 0).diagnosticDescription,
                detail: "frames=\(frameLength)"
            )
        }
    }
}
