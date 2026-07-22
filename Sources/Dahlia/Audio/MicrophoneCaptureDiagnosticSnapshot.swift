@preconcurrency import AVFoundation
import Foundation

struct MicrophoneCaptureDiagnosticSnapshot: Identifiable, Equatable {
    let id: UUID
    let captureID: UUID
    let timestamp: Date
    let context: MicrophoneCaptureContext
    let stage: MicrophoneCaptureDiagnosticStage
    let preferredMicrophoneMode: AVCaptureDevice.MicrophoneMode
    let activeMicrophoneMode: AVCaptureDevice.MicrophoneMode
    let voiceProcessingEnabled: Bool?
    let voiceProcessingBypassed: Bool?
    let voiceProcessingInputMuted: Bool?
    let voiceProcessingAGCEnabled: Bool?
    let requestedVoiceProcessing: Bool?
    let selectedDeviceID: AudioDeviceID?
    let defaultDeviceID: AudioDeviceID?
    let activeDeviceID: AudioDeviceID?
    let activeDeviceName: String?
    let deviceRunningBeforeCapture: Bool?
    let engineRunning: Bool?
    let inputHardwareFormat: String?
    let inputClientFormat: String?
    let outputHardwareFormat: String?
    let targetFormat: String?
    let detail: String?
}
