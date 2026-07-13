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
        detail: String? = nil
    ) {
        MicrophoneCaptureDiagnostics.shared.record(
            captureID: captureID,
            stage: stage,
            voiceProcessingEnabled: inputNode.isVoiceProcessingEnabled,
            voiceProcessingBypassed: inputNode.isVoiceProcessingBypassed,
            voiceProcessingInputMuted: inputNode.isVoiceProcessingInputMuted,
            voiceProcessingAGCEnabled: inputNode.isVoiceProcessingAGCEnabled,
            detail: detail
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
                detail: "frames=\(frameLength)"
            )
        }
    }
}
