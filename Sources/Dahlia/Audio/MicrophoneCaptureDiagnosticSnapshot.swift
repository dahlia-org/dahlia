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
    let detail: String?
}
