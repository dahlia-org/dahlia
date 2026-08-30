import CoreAudio
import Foundation

struct MicrophoneCaptureDiagnosticSnapshot: Identifiable, Equatable {
    let id: UUID
    let captureID: UUID
    let timestamp: Date
    let context: MicrophoneCaptureContext
    let stage: MicrophoneCaptureDiagnosticStage
    let selectedDeviceID: AudioDeviceID?
    let defaultDeviceID: AudioDeviceID?
    let activeDeviceID: AudioDeviceID?
    let activeDeviceName: String?
    let deviceRunningBeforeCapture: Bool?
    let inputHardwareFormat: String?
    let inputClientFormat: String?
    let targetFormat: String?
    let detail: String?
}
