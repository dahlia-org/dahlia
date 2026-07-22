@preconcurrency import AVFoundation

enum AudioCaptureError: Error, LocalizedError {
    case invalidHardwareFormat
    case converterCreationFailed
    case microphonePermissionDenied
    case microphoneDeviceUnavailable
    case echoCancellationUnavailable
    case echoCancellationBypassed
    case diagnosticAudioOutputUnavailable

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
        case .echoCancellationUnavailable:
            L10n.echoCancellationUnavailable
        case .echoCancellationBypassed:
            L10n.echoCancellationBypassed
        case .diagnosticAudioOutputUnavailable:
            L10n.diagnosticAudioOutputUnavailable
        }
    }
}

/// ScreenCaptureKit microphone captureで共有する権限・CoreAudioデバイス照会の名前空間。
enum AudioCaptureManager {
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
}
