import CoreAudio

enum MicrophoneEchoCancellationDecision {
    static func resolveActiveDeviceID(
        selectedDeviceID: AudioDeviceID?,
        defaultDeviceID: @autoclosure () -> AudioDeviceID?
    ) -> AudioDeviceID? {
        selectedDeviceID ?? defaultDeviceID()
    }

    static func isEnabled(
        activeDeviceID: AudioDeviceID?,
        forcesEchoCancellationForExternalMicrophone: Bool,
        isBuiltInDevice: (AudioDeviceID) -> Bool = AudioCaptureManager.isBuiltInInputDevice
    ) -> Bool {
        guard let activeDeviceID else {
            return forcesEchoCancellationForExternalMicrophone
        }
        return isBuiltInDevice(activeDeviceID) || forcesEchoCancellationForExternalMicrophone
    }
}
